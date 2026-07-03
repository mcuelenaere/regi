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
    // The sink converts + feeds frames off the main actor (see SpiceVideoSink)
    // so per-frame pixel work never contends with main-actor input handling.
    private let factory = RTCPeerConnectionFactory()
    private var videoSink: SpiceVideoSink?

    // Channels.
    private var mainConn: SpiceChannelConnection?
    private var main: SpiceMainChannel?
    private var inputs: SpiceInputsChannel?
    private var display: SpiceDisplayChannel?

    // Stats: a ~1 Hz poller diffs the display channel's cumulative counters
    // and the connection's byte total against the previous sample to derive
    // bitrate / FPS / per-frame decode time. `statsAnchor` is that previous
    // reference point (nil until the first tick establishes a baseline).
    private var statsTask: Task<Void, Never>?
    private var statsAnchor: (time: Date, bytes: Int, snapshot: SpiceDisplayChannel.Stats)?
    private static let maxStatsHistory = 60

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
    /// Discrete, order-sensitive events. Pointer *motion* is NOT queued here
    /// — it's coalesced (below) so a flood of positions can't back up the
    /// queue and delay a key-up (which made the guest auto-repeat → "aaa").
    private enum InputEvent {
        case key(SpiceScancode, down: Bool)
        case position(x: UInt32, y: UInt32, buttons: UInt16)   // reliable (clicks)
        case press(SpiceMsg.MouseButton, buttons: UInt16)
        case release(SpiceMsg.MouseButton, buttons: UInt16)
        case motionTick                                        // flush coalesced motion
    }
    private var inputContinuation: AsyncStream<InputEvent>.Continuation?
    private var inputTask: Task<Void, Never>?

    // Coalesced pointer motion: absolute keeps the latest position, relative
    // accumulates deltas. A single `.motionTick` is queued while either is
    // pending, so motion can never grow the queue unbounded.
    private var pendingAbsolute: (x: UInt32, y: UInt32, buttons: UInt16)?
    private var pendingRelative: (dx: Int32, dy: Int32, buttons: UInt16)?
    private var motionTickQueued = false

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
            log.error("SPICE connect failed: \(Self.describe(error), privacy: .public)")
            state = .failed(Self.describe(error))
            await teardown()
            return
        }

        state = .connecting(.signaling)
        setupVideoTrack()

        // Await MAIN_INIT to learn the session id secondary channels use,
        // but never hang: fail if it doesn't arrive (server linked but sent
        // no INIT) or the channel closes first.
        let main = SpiceMainChannel(connection: mainConn)
        self.main = main
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
            log.error("SPICE secondary channels failed: \(Self.describe(error), privacy: .public)")
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
        // Feed WebRTC on the display's emit queue (where onFrame fires), NOT
        // the main actor — the heavy CVPixelBuffer work would otherwise starve
        // the input pump. Only the cheap frame-size note hops to the main actor.
        let sink = videoSink
        display.onFrame = { [weak self] frame in
            sink?.push(frame)
            let size = CGSize(width: frame.width, height: frame.height)
            Task { @MainActor in self?.noteFrameSize(size) }
        }
        display.start()

        state = .connected
        startStatsPolling()
    }

    public func disconnect() async { await teardown(); state = .idle }

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

    /// Tear down channels/video/input. Does NOT touch `state` — the caller
    /// owns it (a failed connect sets `.failed` then calls this; a clean
    /// disconnect sets `.idle` afterwards). Previously this reset `.failed`
    /// back to `.idle`, so connect errors never reached the UI.
    private func teardown() async {
        statsTask?.cancel(); statsTask = nil
        statsAnchor = nil
        latestStats = nil; statsHistory = []
        inputContinuation?.finish(); inputContinuation = nil
        inputTask?.cancel(); inputTask = nil
        display?.stop(); inputs?.stop(); main?.stop()
        await mainConn?.close()
        display = nil; inputs = nil; main = nil; mainConn = nil
        videoTrack = nil; videoSink = nil
        hasReceivedFirstFrame = false
        heldModifiers.removeAll()
        heldKeys.removeAll()
        pendingAbsolute = nil; pendingRelative = nil; motionTickQueued = false
    }

    // MARK: - Stats

    /// Poll the display channel + connection once a second and publish a
    /// derived `ConnectionStats` sample. SPICE is TCP (optionally TLS/proxy),
    /// so the WebRTC-shaped RTT / jitter / packet-loss fields don't apply and
    /// stay nil — the panel shows "—" for those. We surface what's meaningful
    /// for diagnosing lag: bitrate, FPS, decode time, codec, session bytes.
    private func startStatsPolling() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                await self?.sampleStats()
            }
        }
    }

    private func sampleStats() async {
        guard let display, case .connected = state else { return }
        let bytes = await display.connection.bytesReceived
        let snap = display.statsSnapshot()
        let now = Date()
        defer { statsAnchor = (now, bytes, snap) }

        // First tick just establishes the baseline; rates need two samples.
        guard let prev = statsAnchor else { return }
        let dt = now.timeIntervalSince(prev.time)
        guard dt > 0 else { return }

        let deltaBytes = max(0, bytes - prev.bytes)
        let deltaEmitted = max(0, snap.emittedFrames - prev.snapshot.emittedFrames)
        let deltaDecoded = max(0, snap.streamFramesDecoded - prev.snapshot.streamFramesDecoded)
        let deltaDecodeSec = max(0, snap.streamDecodeTimeSec - prev.snapshot.streamDecodeTimeSec)
        let deltaDraws = snap.drawOps - prev.snapshot.drawOps

        let fps = Double(deltaEmitted) / dt
        // Latency is only meaningful while video is actually flowing.
        let videoActive = deltaDecoded > 0
        // Feedback cadence: you see the result of an action on the next frame,
        // so a frame interval is the floor on felt latency. Add the buffering
        // delay above best case to get the round-trip-to-screen estimate.
        let frameIntervalMs = (videoActive && fps > 0) ? 1000.0 / fps : nil
        let playbackDelay = videoActive ? snap.frameDelayMs : nil
        let inputLatency = frameIntervalMs.map { $0 + (playbackDelay ?? 0) }

        // "Codec" reflects how the screen is being delivered *right now*: the
        // stream codec while video frames flow, "Images" when it's the plain
        // image-draw path (no active stream), else keep the last shown value so
        // an idle screen doesn't blank out.
        let deliveredCodec: String?
        if videoActive {
            deliveredCodec = snap.codec?.mimeType
        } else if deltaDraws > 0 {
            deliveredCodec = "Images"
        } else {
            deliveredCodec = latestStats?.codec
        }

        let sample = ConnectionStats(
            timestamp: now,
            roundTripTimeMs: nil,
            jitterMs: nil,
            packetsReceived: 0,
            packetsLost: 0,
            bitrateBitsPerSecond: Double(deltaBytes) * 8 / dt,
            connectionType: nil,
            framesPerSecond: fps,
            framesDropped: Int64(snap.streamFramesDropped),
            codec: deliveredCodec,
            freezeCount: 0,
            totalFreezesDurationSec: 0,
            decodeTimePerFrameMs: deltaDecoded > 0 ? (deltaDecodeSec / Double(deltaDecoded)) * 1000 : nil,
            playbackDelayMs: playbackDelay,
            endToEndLatencyMs: inputLatency,
            bytesReceivedTotal: Int64(bytes)
        )
        latestStats = sample
        statsHistory.append(sample)
        let overshoot = statsHistory.count - Self.maxStatsHistory
        if overshoot > 0 { statsHistory.removeFirst(overshoot) }

        // Diagnostic: where do screen updates actually come from, and is the
        // server's video stream flapping? streamRecv = frames the server sent
        // us (decoded+dropped); emitted = frames we handed the renderer.
        let deltaReceived = (snap.streamFramesDecoded + snap.streamFramesDropped)
            - (prev.snapshot.streamFramesDecoded + prev.snapshot.streamFramesDropped)
        let deltaCreates = snap.streamCreates - prev.snapshot.streamCreates
        log.debug("""
        SPICE rates/s: streamRecv=\(String(format: "%.1f", Double(deltaReceived) / dt)) \
        emitted=\(String(format: "%.1f", fps)) drawOps=\(String(format: "%.1f", Double(deltaDraws) / dt)) \
        streamCreates=\(deltaCreates) drops=\(snap.streamFramesDropped - prev.snapshot.streamFramesDropped)
        """)
    }

    // MARK: - Video

    private func setupVideoTrack() {
        let sink = SpiceVideoSink(factory: factory)
        self.videoSink = sink
        self.videoTrack = sink.track
    }

    /// Record the current frame size for input coordinate mapping. Cheap; runs
    /// on the main actor while the heavy pixel work stays on the emit queue.
    private func noteFrameSize(_ size: CGSize) {
        lastFrameSize = size
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
        case .position(let x, let y, let b):
            await inputs.sendMousePosition(x: x, y: y, buttons: b)
        case .press(let btn, let b):
            await inputs.sendMousePress(btn, buttons: b)
        case .release(let btn, let b):
            await inputs.sendMouseRelease(btn, buttons: b)
        case .motionTick:
            motionTickQueued = false
            if let a = pendingAbsolute {
                pendingAbsolute = nil
                await inputs.sendMousePosition(x: a.x, y: a.y, buttons: a.buttons)
            }
            if let r = pendingRelative {
                pendingRelative = nil
                await inputs.sendMouseMotion(dx: r.dx, dy: r.dy, buttons: r.buttons)
            }
        }
    }

    private func queueMotionTick() {
        guard !motionTickQueued else { return }
        motionTickQueued = true
        inputContinuation?.yield(.motionTick)
    }

    public func sendKeypress(virtualKeyCode keyCode: UInt16, pressed: Bool) {
        guard let sc = SpiceKeyMap.scancode(forVirtualKeyCode: keyCode) else { return }
        if pressed {
            // Drop OS auto-repeat: a single held make code is enough — the
            // guest generates typematic repeat itself.
            if heldKeys.contains(keyCode) { return }
            heldKeys.insert(keyCode)
        } else {
            heldKeys.remove(keyCode)
        }
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
        // Pure motion: coalesce to the latest position.
        guard let p = absolutePixels(normalizedX, normalizedY) else { return }
        pendingAbsolute = (p.x, p.y, Self.buttonMask(buttons))
        queueMotionTick()
    }

    public func sendPointerButtonChange(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons) {
        // Button transitions must be reliable + ordered, so send the position
        // (with the new button mask) through the FIFO, not the coalesced slot.
        guard let p = absolutePixels(normalizedX, normalizedY) else { return }
        pendingAbsolute = nil   // the click position supersedes any pending motion
        inputContinuation?.yield(.position(x: p.x, y: p.y, buttons: Self.buttonMask(buttons)))
    }

    private func absolutePixels(_ x: Int32, _ y: Int32) -> (x: UInt32, y: UInt32)? {
        guard lastFrameSize.width > 0, lastFrameSize.height > 0 else { return nil }
        return (UInt32(max(0, Double(x) / 32767.0 * (lastFrameSize.width - 1))),
                UInt32(max(0, Double(y) / 32767.0 * (lastFrameSize.height - 1))))
    }

    public func sendMouseRelative(dx: Int8, dy: Int8, buttons: MouseButtons) {
        // Coalesce by accumulating deltas so none are lost.
        let mask = Self.buttonMask(buttons)
        if let r = pendingRelative {
            pendingRelative = (r.dx + Int32(dx), r.dy + Int32(dy), mask)
        } else {
            pendingRelative = (Int32(dx), Int32(dy), mask)
        }
        queueMotionTick()
    }

    public func sendWheelReport(wheelY: Int8, wheelX: Int8) {
        guard wheelY != 0 else { return }
        // SPICE encodes wheel as a button up/down press+release.
        let button: SpiceMsg.MouseButton = wheelY > 0 ? .up : .down
        inputContinuation?.yield(.press(button, buttons: 0))
        inputContinuation?.yield(.release(button, buttons: 0))
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

/// Owns the WebRTC video source/track and converts decoded SPICE frames into
/// `RTCVideoFrame`s, feeding them off the main actor. WebRTC video sources
/// accept frames from any thread, so `push` is safe to call from the display
/// channel's emit queue — keeping the 3 MB-per-frame pixel work away from the
/// main actor, where it would otherwise starve the input pump and stall the
/// whole session. A `CVPixelBufferPool` avoids a fresh IOSurface allocation
/// per frame.
final class SpiceVideoSink: @unchecked Sendable {
    let track: RTCVideoTrack
    private let source: RTCVideoSource
    private let capturer: RTCVideoCapturer

    private let lock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0, poolHeight = 0

    init(factory: RTCPeerConnectionFactory) {
        source = factory.videoSource()
        capturer = RTCVideoCapturer(delegate: source)
        track = factory.videoTrack(with: source, trackId: "spice-video")
    }

    /// Convert one decoded BGRA frame and hand it to WebRTC. Callable from any
    /// thread; must NOT be the main actor for a busy stream.
    func push(_ frame: SpiceFrame) {
        guard frame.width > 0, frame.height > 0,
              let pb = pixelBuffer(width: frame.width, height: frame.height) else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let dstStride = CVPixelBufferGetBytesPerRow(pb)
            let srcStride = frame.width * 4
            frame.bgra.withUnsafeBytes { src in
                guard let srcBase = src.baseAddress else { return }
                for row in 0..<frame.height {
                    memcpy(base.advanced(by: row * dstStride),
                           srcBase.advanced(by: row * srcStride), srcStride)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pb)
        let rtcFrame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0,
                                     timeStampNs: Int64(DispatchTime.now().uptimeNanoseconds))
        source.capturer(capturer, didCapture: rtcFrame)
    }

    /// A pooled BGRA pixel buffer for `width`×`height`, rebuilding the pool
    /// when the frame size changes.
    private func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        if pool == nil || width != poolWidth || height != poolHeight {
            let pbAttrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            var newPool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pbAttrs as CFDictionary, &newPool) == kCVReturnSuccess else {
                return nil
            }
            pool = newPool; poolWidth = width; poolHeight = height
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess else { return nil }
        return pb
    }
}
