import Foundation
import JetKVMProtocol
import Observation
import OSLog
import CoreVideo
import WebRTC

private let log = Logger(subsystem: "app.regi.mac", category: "spice")

/// SPICE transport backend. Orchestrates the main, inputs and display
/// channels over one or more `SpiceChannelConnection`s (secondary channels
/// reuse the main channel's `MAIN_INIT.session_id` as their connection id,
/// through the same TLS/proxy), decodes the display into a BGRA framebuffer,
/// and republishes it as a local WebRTC `RTCVideoTrack` so the existing
/// `KVMVideoView` render + coordinate path works unchanged.
///
/// Reached through the `Session` façade for `DeviceKind.spice`. v1 advertises
/// no optional capabilities (video + keyboard/mouse only).
@MainActor
@Observable
public final class SPICEBackend: KVMBackend {
    public private(set) var state: KVMState = .idle
    public private(set) var videoTrack: RTCVideoTrack?
    public private(set) var hasReceivedFirstFrame: Bool = false
    public let capabilities: KVMCapabilities = .none
    public private(set) var latestStats: ConnectionStats?
    public private(set) var statsHistory: [ConnectionStats] = []

    // WebRTC local video plumbing (no peer connection — local render only).
    private let factory = RTCPeerConnectionFactory()
    private var videoSource: RTCVideoSource?
    private var capturer: RTCVideoCapturer?

    // Channels.
    private var mainConn: SpiceChannelConnection?
    private var main: SpiceMainChannel?
    private var inputs: SpiceInputsChannel?
    private var display: SpiceDisplayChannel?

    // Input state.
    private var lastFrameSize = CGSize(width: 0, height: 0)
    private var heldModifiers: Set<UInt16> = []

    public init() {}

    // MARK: - Lifecycle

    public func connect(endpoint: DeviceEndpoint, password: String?) async {
        if case .connecting = state { return }
        await teardown()

        let tls = SpiceTLSConfig(caPEM: endpoint.spiceCAPEM, hostSubject: endpoint.spiceHostSubject)
        let proxy = endpoint.spiceProxy

        state = .connecting(.authenticating)
        let mainConn = makeConnection(endpoint: endpoint, tls: tls, proxy: proxy,
                                      channel: .main, channelID: 0, connectionID: 0)
        self.mainConn = mainConn
        do {
            _ = try await mainConn.connect(password: password)
        } catch SpiceConnectionError.authFailed {
            state = .awaitingPassword(nil)
            await teardown()
            return
        } catch SpiceConnectionError.untrustedCertificate(let reason) {
            state = .awaitingTrustOverride(host: endpoint.host, reason: reason)
            await teardown()
            return
        } catch {
            state = .failed(Self.describe(error))
            await teardown()
            return
        }

        state = .connecting(.signaling)
        setupVideoTrack()

        // Await MAIN_INIT to learn the session id secondary channels use.
        let main = SpiceMainChannel(connection: mainConn)
        self.main = main
        let sessionID: UInt32 = await withCheckedContinuation { cont in
            let resumed = OneShot()
            main.onInit = { info in
                if resumed.fire() { cont.resume(returning: info.sessionID) }
            }
            main.onClosed = { _ in
                if resumed.fire() { cont.resume(returning: 0) }
            }
            main.start()
        }

        // Open inputs + display on the same target, tagged with the session id.
        let inputsConn = makeConnection(endpoint: endpoint, tls: tls, proxy: proxy,
                                        channel: .inputs, channelID: 0, connectionID: sessionID)
        let displayConn = makeConnection(endpoint: endpoint, tls: tls, proxy: proxy,
                                         channel: .display, channelID: 0, connectionID: sessionID)
        do {
            _ = try await inputsConn.connect(password: password)
            _ = try await displayConn.connect(password: password)
        } catch {
            state = .failed(Self.describe(error))
            await teardown()
            return
        }

        let inputs = SpiceInputsChannel(connection: inputsConn)
        self.inputs = inputs
        inputs.start()

        let display = SpiceDisplayChannel(connection: displayConn)
        self.display = display
        display.onFrame = { [weak self] frame in
            Task { @MainActor in self?.pushFrame(frame) }
        }
        display.start()

        state = .connected
    }

    public func disconnect() async { await teardown() }

    public func markFirstFrameReceived() { hasReceivedFirstFrame = true }

    private func makeConnection(endpoint: DeviceEndpoint, tls: SpiceTLSConfig, proxy: SpiceProxy?,
                                channel: SpiceProtocol.ChannelType, channelID: UInt8,
                                connectionID: UInt32) -> SpiceChannelConnection {
        SpiceChannelConnection(
            host: endpoint.host, port: UInt16(endpoint.port), useTLS: endpoint.useTLS,
            allowSelfSigned: endpoint.allowSelfSignedCertificate,
            channelType: channel, channelID: channelID, connectionID: connectionID,
            tlsConfig: tls, proxy: proxy
        )
    }

    private func teardown() async {
        display?.stop(); inputs?.stop(); main?.stop()
        await mainConn?.close()
        display = nil; inputs = nil; main = nil; mainConn = nil
        videoTrack = nil; videoSource = nil; capturer = nil
        hasReceivedFirstFrame = false
        heldModifiers.removeAll()
        if case .connecting = state {} else if state != .idle { state = .idle }
    }

    // MARK: - Video

    private func setupVideoTrack() {
        let source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: "spice-video")
        self.videoSource = source
        self.capturer = RTCVideoCapturer(delegate: source)
        self.videoTrack = track
    }

    /// Convert a decoded BGRA frame to an `RTCVideoFrame` and feed the source.
    private func pushFrame(_ frame: SpiceFrame) {
        guard let source = videoSource, let capturer, frame.width > 0, frame.height > 0 else { return }
        lastFrameSize = CGSize(width: frame.width, height: frame.height)
        guard let pixelBuffer = Self.makeBGRAPixelBuffer(frame) else { return }
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let rtcFrame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0,
                                     timeStampNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000))
        source.capturer(capturer, didCapture: rtcFrame)
    }

    private static func makeBGRAPixelBuffer(_ frame: SpiceFrame) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, frame.width, frame.height,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let dstStride = CVPixelBufferGetBytesPerRow(pb)
        let srcStride = frame.width * 4
        frame.bgra.withUnsafeBytes { src in
            guard let srcBase = src.baseAddress else { return }
            for row in 0..<frame.height {
                memcpy(base.advanced(by: row * dstStride),
                       srcBase.advanced(by: row * srcStride), srcStride)
            }
        }
        return pb
    }

    // MARK: - Input

    public func sendKeypress(virtualKeyCode keyCode: UInt16, pressed: Bool) {
        guard let sc = SpiceKeyMap.scancode(forVirtualKeyCode: keyCode), let inputs else { return }
        Task { pressed ? await inputs.sendKeyDown(sc) : await inputs.sendKeyUp(sc) }
    }

    public func handleFlagsChanged(virtualKeyCode keyCode: UInt16) {
        guard let sc = SpiceKeyMap.scancode(forVirtualKeyCode: keyCode), let inputs else { return }
        let pressed = !heldModifiers.contains(keyCode)
        if pressed { heldModifiers.insert(keyCode) } else { heldModifiers.remove(keyCode) }
        Task { pressed ? await inputs.sendKeyDown(sc) : await inputs.sendKeyUp(sc) }
    }

    public func releaseAllHeldModifiers() {
        guard let inputs else { return }
        let held = heldModifiers
        heldModifiers.removeAll()
        for keyCode in held {
            guard let sc = SpiceKeyMap.scancode(forVirtualKeyCode: keyCode) else { continue }
            Task { await inputs.sendKeyUp(sc) }
        }
    }

    public func sendPointerMotion(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons) {
        sendAbsolute(x: normalizedX, y: normalizedY, buttons: buttons)
    }

    public func sendPointerButtonChange(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons) {
        sendAbsolute(x: normalizedX, y: normalizedY, buttons: buttons)
    }

    private func sendAbsolute(x: Int32, y: Int32, buttons: MouseButtons) {
        guard let inputs, lastFrameSize.width > 0, lastFrameSize.height > 0 else { return }
        let px = UInt32(Double(x) / 32767.0 * (lastFrameSize.width - 1))
        let py = UInt32(Double(y) / 32767.0 * (lastFrameSize.height - 1))
        let mask = Self.buttonMask(buttons)
        Task { await inputs.sendMousePosition(x: px, y: py, buttons: mask) }
    }

    public func sendMouseRelative(dx: Int8, dy: Int8, buttons: MouseButtons) {
        guard let inputs else { return }
        let mask = Self.buttonMask(buttons)
        Task { await inputs.sendMouseMotion(dx: Int32(dx), dy: Int32(dy), buttons: mask) }
    }

    public func sendWheelReport(wheelY: Int8, wheelX: Int8) {
        guard let inputs, wheelY != 0 else { return }
        // SPICE encodes wheel as button up/down press+release.
        let button: SpiceMsg.MouseButton = wheelY > 0 ? .up : .down
        Task {
            await inputs.sendMousePress(button, buttons: 0)
            await inputs.sendMouseRelease(button, buttons: 0)
        }
    }

    public func pauseVideo() {}
    public func resumeVideo() {}

    // MARK: - Helpers

    /// Map the App's button set to the SPICE 3-bit button mask.
    private static func buttonMask(_ buttons: MouseButtons) -> UInt16 {
        var m: UInt16 = 0
        if buttons.contains(.left) { m |= SpiceMsg.ButtonMask.left }
        if buttons.contains(.middle) { m |= SpiceMsg.ButtonMask.middle }
        if buttons.contains(.right) { m |= SpiceMsg.ButtonMask.right }
        return m
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? SpiceConnectionError {
            switch e {
            case .connectionFailed(let m): return "Connection failed: \(m)"
            case .connectionClosed: return "Connection closed"
            case .linkRejected(let err): return "SPICE link rejected (\(err))"
            case .authFailed: return "Authentication failed"
            case .untrustedCertificate(let r): return "Untrusted certificate: \(r)"
            case .protocolError(let m): return "Protocol error: \(m)"
            }
        }
        return "\(error)"
    }
}

/// One-shot latch so a continuation is resumed at most once.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
