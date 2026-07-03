import Foundation
import CoreGraphics
import JetKVMProtocol
import Observation
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "vnc")

/// RFB 3.8 backend for standalone VNC servers (QEMU/libvirt `-vnc`, and Proxmox
/// VMs reached via their QEMU VNC port). Decodes the framebuffer locally and
/// presents it through `LocalVideoOutput` — no WebRTC. Reached through the
/// `Session` façade for `DeviceKind.vnc`.
///
/// `@MainActor` like the other backends so SwiftUI observes its state directly;
/// the socket lives on the `VNCConnection` actor and all pixel work runs on the
/// stream engine's detached task.
@MainActor
@Observable
public final class VNCBackend: KVMBackend {
    public private(set) var state: KVMState = .idle
    /// VNC renders locally, not over WebRTC. The renderer consumes the
    /// presenter's decoded frames; built once, reused across reconnects (the
    /// presenter instance is stable).
    public var videoRenderer: (any KVMVideoRenderer)? { localRenderer }
    // Never reassigned (the presenter is stable), so it needs no observation;
    // `lazy` also isn't allowed on an @Observable stored property.
    @ObservationIgnored private lazy var localRenderer = LocalVideoRenderer(source: presenter)
    public private(set) var hasReceivedFirstFrame: Bool = false
    public var capabilities: KVMCapabilities {
        KVMCapabilities(clipboardSync: true, pauseResume: true)
    }
    /// XVP power control (shutdown/reset), advertised only once the server
    /// negotiates XVP — which requires it to run with power control enabled —
    /// so the Power section stays hidden otherwise. QEMU honours shutdown and
    /// reset but rejects reboot, so we don't offer it.
    public var availablePowerActions: [KVMPowerAction] {
        xvpAvailable ? [.shutdown, .reset] : []
    }
    public private(set) var latestStats: ConnectionStats?
    public private(set) var statsHistory: [ConnectionStats] = []

    /// Set when the server sends an XVP INIT — power control is available.
    /// Drives `availablePowerActions`.
    private(set) var xvpAvailable = false

    /// Text clipboard surface bound by the App-layer sync manager.
    public let textClipboard = VNCTextClipboard()
    private var serverSupportsExtendedClipboard = false
    private var sentExtendedClipboardCaps = false
    private var localClipboardText: String?

    // Converts decoded BGRA frames to CVPixelBuffers off the main actor and
    // hands them straight to the view's layer — no WebRTC pipeline.
    private let presenter = VideoFramePresenter()

    private var connection: VNCConnection?
    private var engine: VNCStreamEngine?
    private var statsCollector: VNCStatsCollector?
    private var streamTask: Task<Void, Never>?

    // Stats: a ~1 Hz poller diffs the collector counters and the connection's
    // byte total against the previous anchor to derive bitrate / FPS / decode
    // time. RTT/jitter/loss don't apply to a plain TCP RFB stream (they stay
    // nil; the panel shows "—").
    private var statsTask: Task<Void, Never>?
    private var statsAnchor: (time: Date, bytes: Int, snapshot: VNCStatsCollector.Snapshot)?
    private static let maxStatsHistory = 60

    // Reconnect: exponential backoff, mirroring JetKVMBackend. Only auto-
    // reconnect after having reached `.connected` this session.
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    /// Bumped by every user connect/disconnect and each reconnect attempt. An
    /// in-flight `establish()` captures the value at entry and bails (closing
    /// its local socket) if a newer attempt supersedes it across an `await` —
    /// preventing two connections/engines from interleaving.
    private var connectGeneration = 0

    /// Most recent framebuffer size, mirrored to the main actor for input
    /// coordinate mapping (used from the input phase onward).
    private(set) var frameSize: CGSize = .zero
    /// Whether the server acked QEMU Extended Key Events (input phase).
    private(set) var useExtendedKeyEvents = false

    // Reconnect bookkeeping (used from the reconnect phase).
    private var lastEndpoint: DeviceEndpoint?
    private var lastPassword: String?
    private var hasBeenConnectedThisSession = false

    // MARK: - Input pump state
    //
    // Discrete, order-sensitive events go through an AsyncStream FIFO drained
    // by one consumer, so a key-up can never overtake its key-down. Pointer
    // *motion* is NOT queued — it's coalesced (latest position wins) and a
    // single `.motionTick` flushes it, so a motion flood can't back up the
    // queue and delay a key event.
    private enum InputEvent {
        case raw(Data)      // pre-encoded key / pointer / wheel message(s)
        case motionTick     // flush the coalesced motion slot
    }
    private var inputContinuation: AsyncStream<InputEvent>.Continuation?
    private var inputTask: Task<Void, Never>?
    private var pendingMotion: (x: Int, y: Int, mask: UInt8)?
    private var motionTickQueued = false
    private var currentButtonMask: UInt8 = 0
    private var lastPointer: (x: Int, y: Int) = (0, 0)
    /// Non-modifier keys currently held (to drop OS auto-repeat and release on
    /// focus loss).
    private var heldKeys: Set<UInt16> = []
    private var heldModifiers: Set<UInt16> = []

    public init() {
        textClipboard.onLocalText = { [weak self] text in
            self?.localClipboardChanged(text)
        }
    }

    // MARK: - Lifecycle

    public func connect(endpoint: DeviceEndpoint, password: String?) async {
        // User-initiated: reset the reconnect cycle and supersede any in-flight
        // establish().
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        connectGeneration += 1
        let generation = connectGeneration
        lastEndpoint = endpoint
        lastPassword = password
        await establish(endpoint: endpoint, password: password, generation: generation)
    }

    /// The connect flow, reused by both user-initiated connects and reconnect
    /// attempts (the latter keeps `reconnectAttempt` intact). `generation`
    /// guards against a superseding attempt: the local socket isn't published
    /// to `self.connection` until every `await` has cleared, and each resume
    /// re-checks the generation so a stale attempt closes its socket and bails
    /// rather than clobbering the newer one.
    private func establish(endpoint: DeviceEndpoint, password: String?, generation: Int) async {
        await teardown()
        guard generation == connectGeneration else { return }
        state = .connecting(.checkingStatus)

        let conn = VNCConnection(
            host: endpoint.host, port: UInt16(clamping: endpoint.port),
            useTLS: endpoint.useTLS,
            allowSelfSigned: endpoint.allowSelfSignedCertificate,
            username: endpoint.username)
        do {
            try await conn.open(hasPassword: !(password ?? "").isEmpty)
            guard generation == connectGeneration else { await conn.close(); return }
            state = .connecting(.authenticating)
            let serverInit = try await conn.handshake(password: password)
            guard generation == connectGeneration else { await conn.close(); return }
            log.info("VNC connected: \(serverInit.width)x\(serverInit.height) '\(serverInit.name, privacy: .public)'")

            try await conn.send(RFBProtocol.setPixelFormat(.bgra32))
            try await conn.send(RFBProtocol.setEncodings(Self.encodings))
            guard generation == connectGeneration else { await conn.close(); return }

            // Commit: publish the socket and bring up the pipeline. No `await`
            // from here to `.connected`, so this runs atomically on the main
            // actor and can't interleave with another attempt.
            connection = conn
            let stats = VNCStatsCollector()
            statsCollector = stats
            let engine = VNCStreamEngine(
                channel: conn, presenter: presenter,
                width: serverInit.width, height: serverInit.height,
                pixelFormat: .bgra32, stats: stats)
            wireCallbacks(engine)
            self.engine = engine
            frameSize = CGSize(width: serverInit.width, height: serverInit.height)

            streamTask = Task.detached(priority: .userInitiated) { await engine.run() }
            startInputPump()
            startStatsPolling()
            textClipboard.isAvailable = true
            state = .connected
            hasBeenConnectedThisSession = true
            reconnectAttempt = 0
        } catch let error as VNCConnectionError {
            await conn.close()
            guard generation == connectGeneration else { return }
            await teardown()
            switch error {
            case .authFailed:
                // Terminal: the user must (re)enter a password. Stops any
                // reconnect loop.
                reconnectTask?.cancel()
                reconnectTask = nil
                reconnectAttempt = 0
                state = .awaitingPassword
            case .untrustedCertificate(let reason):
                // Surface the trust-override prompt; the App retries with
                // allowSelfSignedCertificate once the user accepts.
                reconnectTask?.cancel()
                reconnectTask = nil
                reconnectAttempt = 0
                state = .awaitingTrustOverride(host: endpoint.host, reason: reason)
            default:
                handleConnectFailure(Self.describe(error))
            }
        } catch {
            await conn.close()
            guard generation == connectGeneration else { return }
            await teardown()
            handleConnectFailure("\(error)")
        }
    }

    /// After a failed connect: auto-reconnect with backoff if we'd previously
    /// been connected this session, else surface the failure.
    private func handleConnectFailure(_ message: String) {
        if hasBeenConnectedThisSession {
            scheduleReconnect()
        } else {
            state = .failed(message)
        }
    }

    /// Exponential backoff: 1, 2, 4, 8, 16, capped at 30 s. Mirrors
    /// `JetKVMBackend`. `reconnectAttempt` persists across the cycle and resets
    /// on `.connected` or a user-initiated connect/disconnect.
    private func scheduleReconnect() {
        guard let endpoint = lastEndpoint else {
            state = .failed("connection lost")
            return
        }
        reconnectAttempt += 1
        let backoff = min(30, 1 << min(reconnectAttempt - 1, 4))
        log.info("scheduling VNC reconnect attempt \(self.reconnectAttempt, privacy: .public) in \(backoff, privacy: .public)s")
        state = .reconnecting(attempt: reconnectAttempt)
        let password = lastPassword
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(backoff))
            guard let self, !Task.isCancelled else { return }
            self.connectGeneration += 1
            let generation = self.connectGeneration
            await self.establish(endpoint: endpoint, password: password, generation: generation)
        }
    }

    public func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        connectGeneration += 1 // abort any in-flight establish()
        await teardown()
        state = .idle
    }

    public func markFirstFrameReceived() {
        hasReceivedFirstFrame = true
    }

    /// Tear down transport + tasks. Never touches `state` — the caller owns
    /// state transitions (a failed connect's `.failed`/`.awaitingPassword`
    /// must not be clobbered back to `.idle`).
    private func teardown() async {
        statsTask?.cancel()
        statsTask = nil
        statsAnchor = nil
        streamTask?.cancel()
        streamTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        inputTask?.cancel()
        inputTask = nil
        pendingMotion = nil
        motionTickQueued = false
        currentButtonMask = 0
        heldKeys.removeAll()
        heldModifiers.removeAll()
        useExtendedKeyEvents = false
        textClipboard.isAvailable = false
        textClipboard.supportsUTF8 = false
        serverSupportsExtendedClipboard = false
        sentExtendedClipboardCaps = false
        xvpAvailable = false
        engine = nil
        statsCollector = nil
        if let conn = connection {
            await conn.close()
        }
        connection = nil
        // Note: we do NOT tear down `localRenderer` here — it's wired to the
        // stable `presenter` and reused across reconnects. The host view calls
        // `videoRenderer.detach()` when the window closes.
    }

    private func wireCallbacks(_ engine: VNCStreamEngine) {
        engine.onFrameSize = { [weak self] w, h in
            Task { @MainActor in self?.frameSize = CGSize(width: w, height: h) }
        }
        engine.onError = { [weak self] message in
            Task { @MainActor in self?.handleStreamError(message) }
        }
        engine.onExtKeyEventAck = { [weak self] in
            Task { @MainActor in self?.useExtendedKeyEvents = true }
        }
        engine.onClipboard = { [weak self] inbound in
            Task { @MainActor in self?.handleInboundClipboard(inbound) }
        }
        engine.onXVP = { [weak self] code, _ in
            Task { @MainActor in self?.handleXVP(code: code) }
        }
    }

    // MARK: - Power control (XVP)

    private func handleXVP(code: UInt8) {
        switch code {
        case RFBProtocol.XVP.codeInit:
            log.info("XVP power control available")
            xvpAvailable = true
        case RFBProtocol.XVP.codeFail:
            log.notice("XVP action rejected by server")
        default:
            break
        }
    }

    /// Send an XVP power action. No-op unless connected, the server negotiated
    /// XVP, and the action maps to a supported XVP op.
    public func sendPowerAction(_ action: KVMPowerAction) {
        guard case .connected = state, xvpAvailable else { return }
        let wire: UInt8
        switch action {
        case .shutdown: wire = RFBProtocol.XVP.actionShutdown
        case .reboot: wire = RFBProtocol.XVP.actionReboot
        case .reset: wire = RFBProtocol.XVP.actionReset
        case .powerButtonShort, .powerButtonLong: return  // not XVP actions
        }
        enqueue(RFBProtocol.xvp(action: wire))
    }

    // MARK: - Clipboard

    private func handleInboundClipboard(_ inbound: VNCInboundClipboard) {
        switch inbound {
        case .classicText(let text):
            textClipboard.onRemoteText?(text)
        case .extended(let message):
            handleExtendedClipboard(message)
        }
    }

    private func handleExtendedClipboard(_ message: VNCExtendedClipboard.Message) {
        switch message {
        case .caps:
            serverSupportsExtendedClipboard = true
            textClipboard.supportsUTF8 = true
            // Answer with our caps exactly once per connection.
            if !sentExtendedClipboardCaps {
                sentExtendedClipboardCaps = true
                sendExtendedClipboard(VNCExtendedClipboard.encodeCaps())
            }
        case .request:
            if let text = localClipboardText, let payload = try? VNCExtendedClipboard.encodeProvide(text: text) {
                sendExtendedClipboard(payload)
            }
        case .peek:
            sendExtendedClipboard(VNCExtendedClipboard.encodeNotify(hasText: localClipboardText != nil))
        case .notify(let formats):
            if formats.contains(.text) {
                sendExtendedClipboard(VNCExtendedClipboard.encodeRequestText())
            }
        case .provide(let text):
            if let text { textClipboard.onRemoteText?(text) }
        }
    }

    /// Called by the sync manager when the local pasteboard text changes.
    private func localClipboardChanged(_ text: String?) {
        localClipboardText = text
        guard case .connected = state, let text, !text.isEmpty else { return }
        if serverSupportsExtendedClipboard {
            // Announce; the server requests, then we provide.
            sendExtendedClipboard(VNCExtendedClipboard.encodeNotify(hasText: true))
        } else {
            // Classic fallback: ship the Latin-1 text immediately.
            enqueue(RFBProtocol.clientCutText(latin1: text))
        }
    }

    private func sendExtendedClipboard(_ payload: Data) {
        enqueue(RFBProtocol.clientCutTextExtended(payload: payload))
    }

    private func handleStreamError(_ message: String) {
        // Only meaningful while we thought we were connected.
        guard case .connected = state else { return }
        log.error("VNC stream error: \(message, privacy: .public)")
        // Flip state synchronously so a second error arriving in the same
        // main-actor tick bails at the guard above (avoids a double reconnect
        // schedule / inflated attempt counter). The provisional attempt matches
        // what scheduleReconnect will set.
        state = .reconnecting(attempt: reconnectAttempt + 1)
        Task { @MainActor in
            await self.teardown()
            self.scheduleReconnect()
        }
    }

    // MARK: - Bandwidth gate

    public func pauseVideo() {
        engine?.paused = true
    }

    public func resumeVideo() {
        guard let engine, let connection, case .connected = state else { return }
        engine.paused = false
        // Kick a full repaint. Build the request from the main-actor `frameSize`
        // and send it via the connection actor — we must NOT read the
        // framebuffer here (it's confined to the decode task; the server clamps
        // the size anyway).
        let w = Int(frameSize.width), h = Int(frameSize.height)
        guard w > 0, h > 0 else { return }
        let request = RFBProtocol.framebufferUpdateRequest(incremental: false, x: 0, y: 0, width: w, height: h)
        Task { try? await connection.send(request) }
    }

    // MARK: - Input

    /// Drain the input FIFO in order, sending each event before the next so
    /// key/click ordering is preserved on the wire.
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
        guard let conn = connection else { return }
        switch event {
        case .raw(let data):
            try? await conn.send(data)
        case .motionTick:
            motionTickQueued = false
            if let m = pendingMotion {
                pendingMotion = nil
                try? await conn.send(RFBProtocol.pointerEvent(buttonMask: m.mask, x: m.x, y: m.y))
            }
        }
    }

    private func enqueue(_ data: Data) { inputContinuation?.yield(.raw(data)) }

    private func queueMotionTick() {
        guard !motionTickQueued else { return }
        motionTickQueued = true
        inputContinuation?.yield(.motionTick)
    }

    public func sendKeypress(virtualKeyCode keyCode: UInt16, pressed: Bool) {
        if pressed {
            // Drop OS auto-repeat: one held key is enough — the guest does its
            // own typematic repeat.
            if heldKeys.contains(keyCode) { return }
            heldKeys.insert(keyCode)
        } else {
            heldKeys.remove(keyCode)
        }
        enqueueKey(virtualKeyCode: keyCode, down: pressed)
    }

    public func handleFlagsChanged(virtualKeyCode keyCode: UInt16) {
        let pressed = !heldModifiers.contains(keyCode)
        if pressed { heldModifiers.insert(keyCode) } else { heldModifiers.remove(keyCode) }
        enqueueKey(virtualKeyCode: keyCode, down: pressed)
    }

    public func releaseAllHeldModifiers() {
        // Fires on focus loss — leaving anything down would strand it on the
        // guest.
        let held = heldModifiers.union(heldKeys)
        heldModifiers.removeAll()
        heldKeys.removeAll()
        for keyCode in held {
            enqueueKey(virtualKeyCode: keyCode, down: false)
        }
    }

    private func enqueueKey(virtualKeyCode: UInt16, down: Bool) {
        let shifted = heldModifiers.contains(0x38) || heldModifiers.contains(0x3C)
        guard let key = VNCKeyMap.key(forVirtualKeyCode: virtualKeyCode, shifted: shifted) else { return }
        if useExtendedKeyEvents {
            enqueue(RFBProtocol.qemuExtendedKeyEvent(keysym: key.keysym, keycode: key.xtKeycode, down: down))
        } else if key.keysym != 0 {
            enqueue(RFBProtocol.keyEvent(keysym: key.keysym, down: down))
        }
    }

    public func sendPointerMotion(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons) {
        guard let p = absolutePixels(normalizedX, normalizedY) else { return }
        lastPointer = p
        let mask = Self.rfbMask(buttons)
        currentButtonMask = mask
        pendingMotion = (p.x, p.y, mask)
        queueMotionTick()
    }

    public func sendPointerButtonChange(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons) {
        guard let p = absolutePixels(normalizedX, normalizedY) else { return }
        lastPointer = p
        let mask = Self.rfbMask(buttons)
        currentButtonMask = mask
        // A click position supersedes any pending motion, and must be reliable
        // + ordered — send through the FIFO, not the coalesced slot.
        pendingMotion = nil
        enqueue(RFBProtocol.pointerEvent(buttonMask: mask, x: p.x, y: p.y))
    }

    public func sendMouseRelative(dx: Int8, dy: Int8, buttons: MouseButtons) {
        // Pointer lock: fold deltas onto the virtual absolute cursor, clamped
        // to the framebuffer. QEMU's tablet tracks it 1:1.
        let w = Int(frameSize.width), h = Int(frameSize.height)
        guard w > 0, h > 0 else { return }
        let nx = min(max(lastPointer.x + Int(dx), 0), w - 1)
        let ny = min(max(lastPointer.y + Int(dy), 0), h - 1)
        lastPointer = (nx, ny)
        let mask = Self.rfbMask(buttons)
        currentButtonMask = mask
        pendingMotion = (nx, ny, mask)
        queueMotionTick()
    }

    public func sendWheelReport(wheelY: Int8, wheelX: Int8) {
        // Wheel is transient button presses (4/5 vertical, 6/7 horizontal),
        // anchored at the last pointer position with the held buttons kept.
        var msgs = Data()
        func presses(bit: UInt8, count: Int) {
            for _ in 0..<min(count, 8) {
                msgs.append(RFBProtocol.pointerEvent(buttonMask: currentButtonMask | bit, x: lastPointer.x, y: lastPointer.y))
                msgs.append(RFBProtocol.pointerEvent(buttonMask: currentButtonMask, x: lastPointer.x, y: lastPointer.y))
            }
        }
        // Widen to Int before negating — negating Int8.min (-128) in Int8 traps.
        if wheelY > 0 { presses(bit: 0x08, count: Int(wheelY)) }        // up → button 4
        else if wheelY < 0 { presses(bit: 0x10, count: -Int(wheelY)) }  // down → button 5
        if wheelX > 0 { presses(bit: 0x40, count: Int(wheelX)) }        // right → button 7
        else if wheelX < 0 { presses(bit: 0x20, count: -Int(wheelX)) }  // left → button 6
        if !msgs.isEmpty { enqueue(msgs) }
    }

    private func absolutePixels(_ nx: Int32, _ ny: Int32) -> (x: Int, y: Int)? {
        let w = Int(frameSize.width), h = Int(frameSize.height)
        guard w > 0, h > 0 else { return nil }
        let x = Int((Double(nx) / 32767.0) * Double(w - 1))
        let y = Int((Double(ny) / 32767.0) * Double(h - 1))
        return (min(max(x, 0), w - 1), min(max(y, 0), h - 1))
    }

    /// Translate the App's `MouseButtons` bitmask to the RFB PointerEvent mask
    /// (bit0 left, bit1 middle, bit2 right; back → button 8).
    private static func rfbMask(_ b: MouseButtons) -> UInt8 {
        var m: UInt8 = 0
        if b.contains(.left) { m |= 0x01 }
        if b.contains(.middle) { m |= 0x02 }
        if b.contains(.right) { m |= 0x04 }
        if b.contains(.back) { m |= 0x80 }
        return m
    }

    // MARK: - Stats

    private func startStatsPolling() {
        statsTask?.cancel()
        statsAnchor = nil
        latestStats = nil
        statsHistory = []
        statsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                await self.sampleStats()
            }
        }
    }

    private func sampleStats() async {
        guard let statsCollector, let connection else { return }
        let snap = statsCollector.snapshot()
        let bytes = await connection.bytesReceived
        let now = Date()
        guard let anchor = statsAnchor else {
            statsAnchor = (now, bytes, snap)
            return
        }
        let dt = now.timeIntervalSince(anchor.time)
        guard dt > 0 else { return }

        let deltaBytes = bytes - anchor.bytes
        let deltaFrames = snap.framesPresented - anchor.snapshot.framesPresented
        let deltaDecode = snap.decodeTimeSec - anchor.snapshot.decodeTimeSec
        let fps = Double(deltaFrames) / dt

        // Dominant encoding this window drives the codec label (keep the last
        // when idle).
        let dRaw = snap.rawRects - anchor.snapshot.rawRects
        let dCopy = snap.copyRects - anchor.snapshot.copyRects
        let dTight = snap.tightRects - anchor.snapshot.tightRects
        let dJPEG = snap.tightJPEGRects - anchor.snapshot.tightJPEGRects
        let dZRLE = snap.zrleRects - anchor.snapshot.zrleRects
        let dZlib = snap.zlibRects - anchor.snapshot.zlibRects
        let dHextile = snap.hextileRects - anchor.snapshot.hextileRects
        let dH264 = snap.h264Rects - anchor.snapshot.h264Rects
        let codecLabel: String?
        if dH264 > 0 { codecLabel = "H.264" }
        else if dTight > 0 { codecLabel = dJPEG > 0 ? "Tight (JPEG)" : "Tight" }
        else if dZRLE > 0 { codecLabel = "ZRLE" }
        else if dZlib > 0 { codecLabel = "Zlib" }
        else if dHextile > 0 { codecLabel = "Hextile" }
        else if dRaw > 0 { codecLabel = "Raw" }
        else if dCopy > 0 { codecLabel = "CopyRect" }
        else { codecLabel = latestStats?.codec }

        let frameIntervalMs = deltaFrames > 0 ? (dt / Double(deltaFrames)) * 1000 : nil
        let sample = ConnectionStats(
            timestamp: now,
            roundTripTimeMs: nil,
            jitterMs: nil,
            packetsReceived: 0,
            packetsLost: 0,
            bitrateBitsPerSecond: Double(deltaBytes) * 8 / dt,
            connectionType: nil,
            framesPerSecond: fps,
            framesDropped: 0,
            codec: codecLabel,
            freezeCount: 0,
            totalFreezesDurationSec: 0,
            decodeTimePerFrameMs: deltaFrames > 0 ? (deltaDecode / Double(deltaFrames)) * 1000 : nil,
            playbackDelayMs: nil,
            endToEndLatencyMs: frameIntervalMs,
            bytesReceivedTotal: Int64(bytes)
        )
        latestStats = sample
        statsHistory.append(sample)
        let overshoot = statsHistory.count - Self.maxStatsHistory
        if overshoot > 0 { statsHistory.removeFirst(overshoot) }
        statsAnchor = (now, bytes, snap)
    }

    // MARK: - Config

    /// Encodings we advertise, preference-first. Tight leads (it's QEMU's most
    /// efficient encoder, and the server picks the first it supports), with
    /// ZRLE / Zlib / Hextile as progressively simpler fallbacks for servers
    /// that don't offer Tight, then CopyRect for scrolls and Raw as the
    /// mandatory last resort, then the pseudo-encodings.
    private static let encodings: [Int32] = [
        RFBProtocol.Encoding.h264,
        RFBProtocol.Encoding.tight,
        RFBProtocol.Encoding.zrle,
        RFBProtocol.Encoding.zlib,
        RFBProtocol.Encoding.hextile,
        RFBProtocol.Encoding.copyRect,
        RFBProtocol.Encoding.raw,
        RFBProtocol.Encoding.compressionLevel(2),
        RFBProtocol.Encoding.jpegQuality(8),
        RFBProtocol.Encoding.desktopSize,
        RFBProtocol.Encoding.lastRect,
        RFBProtocol.Encoding.qemuExtendedKeyEvent,
        RFBProtocol.Encoding.extendedClipboard,
        RFBProtocol.Encoding.xvp,
    ]

    private static func describe(_ error: VNCConnectionError) -> String {
        switch error {
        case .connectionFailed(let m): return "Connection failed: \(m)"
        case .connectionClosed: return "Connection closed"
        case .protocolError(let m): return "Protocol error: \(m)"
        case .handshakeFailed(let m): return "Handshake failed: \(m)"
        case .authFailed(let m): return "Authentication failed: \(m)"
        case .unsupportedVersion(let m): return "Unsupported RFB version: \(m)"
        case .untrustedCertificate(let m): return "Untrusted certificate: \(m)"
        }
    }
}
