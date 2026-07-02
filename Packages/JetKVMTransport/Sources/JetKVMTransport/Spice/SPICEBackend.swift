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
    /// Non-modifier keys currently held down, so we can drop OS auto-repeat
    /// key-downs (the guest does its own typematic repeat from one held make
    /// code — resending makes would double it) and release everything on
    /// focus loss.
    private var heldKeys: Set<UInt16> = []

    /// Ordered input pipeline. The App's input callbacks are synchronous but
    /// the channel sends are async; enqueueing here and draining from a
    /// single consumer guarantees key/mouse events reach the server in the
    /// exact order they occurred (spawning a Task per event does not, which
    /// caused a key-up to overtake its key-down → stuck keys).
    private enum InputEvent {
        case key(SpiceScancode, down: Bool)
        case mouseAbsolute(x: UInt32, y: UInt32, buttons: UInt16)
        case mouseRelative(dx: Int32, dy: Int32, buttons: UInt16)
        case mousePress(SpiceMsg.MouseButton, buttons: UInt16)
        case mouseRelease(SpiceMsg.MouseButton, buttons: UInt16)
    }
    private var inputContinuation: AsyncStream<InputEvent>.Continuation?
    private var inputTask: Task<Void, Never>?

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
            try await Self.withTimeout(12) { _ = try await mainConn.connect(password: password) }
        } catch SpiceConnectionError.authFailed {
            // SPICE tickets come from the .vv and can't be re-entered, so a
            // rejection is terminal (usually an expired ticket).
            state = .failed("SPICE ticket rejected — it may have expired. Download a fresh console (.vv) file and reconnect.")
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
        main.onMouseMode = { mode in
            log.notice("SPICE server mouse mode now: \(mode == .client ? "client/absolute" : "server/relative")")
        }
        // Await MAIN_INIT, but never hang: fail if it doesn't arrive (server
        // linked but sent no INIT) or the channel closes first.
        let initInfo: SpiceMsgMainInit? = await withCheckedContinuation { cont in
            let resumed = OneShot()
            main.onInit = { info in if resumed.fire() { cont.resume(returning: info) } }
            main.onClosed = { _ in if resumed.fire() { cont.resume(returning: nil) } }
            main.start()
            Task {
                try? await Task.sleep(for: .seconds(10))
                if resumed.fire() { cont.resume(returning: nil) }
            }
        }
        guard let initInfo else {
            state = .failed("Timed out establishing the SPICE session. The console ticket may have expired — download a fresh .vv and reconnect.")
            await teardown()
            return
        }
        let supportsClient = initInfo.supportedMouseModes & UInt32(SpiceProtocol.MouseMode.client.rawValue) != 0
        log.notice("SPICE MAIN_INIT: mouse supported=\(initInfo.supportedMouseModes) current=\(initInfo.currentMouseMode) clientCapable=\(supportsClient)")
        let sessionID = initInfo.sessionID

        // Open inputs + display on the same target, tagged with the session id.
        let inputsConn = makeConnection(endpoint: endpoint, tls: tls, proxy: proxy,
                                        channel: .inputs, channelID: 0, connectionID: sessionID)
        let displayConn = makeConnection(endpoint: endpoint, tls: tls, proxy: proxy,
                                         channel: .display, channelID: 0, connectionID: sessionID)
        do {
            try await Self.withTimeout(12) {
                _ = try await inputsConn.connect(password: password)
                _ = try await displayConn.connect(password: password)
            }
        } catch {
            state = .failed(Self.describe(error))
            await teardown()
            return
        }

        let inputs = SpiceInputsChannel(connection: inputsConn)
        self.inputs = inputs
        inputs.start()
        startInputPump()

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
        inputContinuation?.finish(); inputContinuation = nil
        inputTask?.cancel(); inputTask = nil
        display?.stop(); inputs?.stop(); main?.stop()
        await mainConn?.close()
        display = nil; inputs = nil; main = nil; mainConn = nil
        videoTrack = nil; videoSource = nil; capturer = nil
        hasReceivedFirstFrame = false
        heldModifiers.removeAll()
        heldKeys.removeAll()
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

    /// Drain the input queue in order, sending each event before the next.
    private func startInputPump() {
        let (stream, cont) = AsyncStream.makeStream(of: InputEvent.self)
        inputContinuation = cont
        inputTask = Task { [weak self] in
            for await event in stream {
                await self?.deliver(event)
            }
        }
    }

    private func deliver(_ event: InputEvent) async {
        guard let inputs else { return }
        switch event {
        case .key(let sc, let down):
            down ? await inputs.sendKeyDown(sc) : await inputs.sendKeyUp(sc)
        case .mouseAbsolute(let x, let y, let b):
            await inputs.sendMousePosition(x: x, y: y, buttons: b)
        case .mouseRelative(let dx, let dy, let b):
            await inputs.sendMouseMotion(dx: dx, dy: dy, buttons: b)
        case .mousePress(let btn, let b):
            await inputs.sendMousePress(btn, buttons: b)
        case .mouseRelease(let btn, let b):
            await inputs.sendMouseRelease(btn, buttons: b)
        }
    }

    public func sendKeypress(virtualKeyCode keyCode: UInt16, pressed: Bool) {
        guard let sc = SpiceKeyMap.scancode(forVirtualKeyCode: keyCode) else { return }
        if pressed {
            // Drop OS auto-repeat: a single held make code is enough — the
            // guest generates typematic repeat itself.
            if heldKeys.contains(keyCode) {
                log.notice("SPICE key vk=\(keyCode) down: dropped (auto-repeat)")
                return
            }
            heldKeys.insert(keyCode)
        } else {
            heldKeys.remove(keyCode)
        }
        log.notice("SPICE key vk=\(keyCode) \(pressed ? "DOWN" : "up") sc=0x\(String(sc.wireCode, radix: 16))")
        inputContinuation?.yield(.key(sc, down: pressed))
    }

    public func handleFlagsChanged(virtualKeyCode keyCode: UInt16) {
        guard let sc = SpiceKeyMap.scancode(forVirtualKeyCode: keyCode) else { return }
        let pressed = !heldModifiers.contains(keyCode)
        if pressed { heldModifiers.insert(keyCode) } else { heldModifiers.remove(keyCode) }
        inputContinuation?.yield(.key(sc, down: pressed))
    }

    public func releaseAllHeldModifiers() {
        // Release both held modifiers and held keys — this fires on focus
        // loss, where leaving anything down would strand it on the guest.
        let held = heldModifiers.union(heldKeys)
        heldModifiers.removeAll()
        heldKeys.removeAll()
        for keyCode in held {
            guard let sc = SpiceKeyMap.scancode(forVirtualKeyCode: keyCode) else { continue }
            inputContinuation?.yield(.key(sc, down: false))
        }
    }

    public func sendPointerMotion(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons) {
        enqueueAbsolute(x: normalizedX, y: normalizedY, buttons: buttons)
    }

    public func sendPointerButtonChange(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons) {
        enqueueAbsolute(x: normalizedX, y: normalizedY, buttons: buttons)
    }

    private func enqueueAbsolute(x: Int32, y: Int32, buttons: MouseButtons) {
        guard lastFrameSize.width > 0, lastFrameSize.height > 0 else { return }
        let px = UInt32(max(0, Double(x) / 32767.0 * (lastFrameSize.width - 1)))
        let py = UInt32(max(0, Double(y) / 32767.0 * (lastFrameSize.height - 1)))
        inputContinuation?.yield(.mouseAbsolute(x: px, y: py, buttons: Self.buttonMask(buttons)))
    }

    public func sendMouseRelative(dx: Int8, dy: Int8, buttons: MouseButtons) {
        inputContinuation?.yield(.mouseRelative(dx: Int32(dx), dy: Int32(dy), buttons: Self.buttonMask(buttons)))
    }

    public func sendWheelReport(wheelY: Int8, wheelX: Int8) {
        guard wheelY != 0 else { return }
        // SPICE encodes wheel as a button up/down press+release.
        let button: SpiceMsg.MouseButton = wheelY > 0 ? .up : .down
        inputContinuation?.yield(.mousePress(button, buttons: 0))
        inputContinuation?.yield(.mouseRelease(button, buttons: 0))
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

    /// Run `op` but fail if it doesn't finish in `seconds` — bounds the link
    /// handshake reads, which otherwise hang forever if the server accepts
    /// the socket but never replies (e.g. a rejected/expired ticket).
    private static func withTimeout(_ seconds: Double,
                                    _ op: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw SpiceConnectionError.connectionFailed("timed out after \(Int(seconds))s")
            }
            try await group.next()
            group.cancelAll()
        }
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
