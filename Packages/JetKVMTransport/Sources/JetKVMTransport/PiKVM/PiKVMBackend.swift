import Foundation
import JetKVMProtocol
import Observation
import OSLog
import WebRTC

private let log = Logger(subsystem: "app.regi.mac", category: "pikvm")

/// PiKVM transport backend. Two concurrent connections:
///   - a Janus WebRTC peer connection for H.264 video (answerer mode), and
///   - a `/api/ws` WebSocket carrying JSON keyboard/mouse events + state.
/// Control (ATX, etc.) is out of scope for v1, so `capabilities` is empty
/// and the App layer hides the JetKVM-only UI.
///
/// Reached through the `Session` façade for `DeviceKind.piKVM`.
@MainActor
@Observable
public final class PiKVMBackend: KVMBackend {
    public private(set) var state: KVMState = .idle
    public private(set) var videoRenderer: (any KVMVideoRenderer)?
    public private(set) var hasReceivedFirstFrame: Bool = false
    public let capabilities: KVMCapabilities = .none
    public private(set) var latestStats: ConnectionStats?
    public private(set) var statsHistory: [ConnectionStats] = []
    public static let maxStatsHistory = 60

    // Transport
    private var http: PiKVMHTTPClient?
    private var janus: JanusSignalingClient?
    private var events: PiKVMEventClient?
    private var webrtc: WebRTCFacade?
    private var pumpTasks: [Task<Void, Never>] = []

    // Input state
    private var modifierTracker = ModifierTracker()
    private var pointerThrottler = InputThrottler(interval: .milliseconds(8))
    private var heldModifierCodes: Set<String> = []
    private var lastButtons: MouseButtons = []
    /// Whether the device's mouse gadget is in absolute mode (from the
    /// `hid` state event). Drives a log warning if we send `mouse_move`
    /// to a relative-only device; routing itself is decided by the UI
    /// (pointer lock) via `sendMouseRelative` vs `sendPointerMotion`.
    private var mouseAbsolute = true

    /// MouseButtons bit → PiKVM button name. back/forward surface as the
    /// 4th/5th buttons (`up`/`down`) the web client uses.
    private static let buttonMap: [(MouseButtons, PiKVMEvent.MouseButton)] = [
        (.left, .left), (.right, .right), (.middle, .middle),
        (.back, .up), (.forward, .down),
    ]

    public init() {}

    // MARK: - Lifecycle

    public func connect(endpoint: DeviceEndpoint, password: String?) async {
        if case .connecting = state { return }
        await teardown()

        let user = endpoint.username ?? "admin"

        // 1. Authenticate. No password yet → ask the UI for one.
        guard let password, !password.isEmpty else {
            state = .awaitingPassword
            return
        }

        state = .connecting(.authenticating)
        let http = PiKVMHTTPClient(endpoint: endpoint)
        self.http = http
        do {
            try await http.login(user: user, password: password)
        } catch HTTPClientError.unauthorized {
            log.notice("PiKVM login rejected")
            state = .awaitingPassword
            await teardown()
            return
        } catch HTTPClientError.untrustedServerCertificate(let reason) {
            state = .awaitingTrustOverride(host: endpoint.host, reason: reason)
            await teardown()
            return
        } catch {
            state = .failed(Self.describe(error))
            await teardown()
            return
        }

        do {
            // 2. Open the input/state channel.
            state = .connecting(.signaling)
            let events = PiKVMEventClient(endpoint: endpoint, cookieStorage: http.cookieStorage)
            self.events = events
            try await events.connect()

            // 3. Janus: session + plugin, then watch for the video offer.
            let janus = JanusSignalingClient(endpoint: endpoint, cookieStorage: http.cookieStorage)
            self.janus = janus
            try await janus.connect()

            state = .connecting(.offering)
            let offerSDP = try await janus.watch()

            // 4. Answer the offer with a video-only peer connection.
            let webrtc = WebRTCFacade()
            self.webrtc = webrtc
            startPumps(webrtc: webrtc, janus: janus, events: events)

            state = .connecting(.awaitingAnswer)
            let answerSDP = try await webrtc.startAnswerer(offerSDP: offerSDP)
            try await janus.sendAnswer(answerSDP)
            state = .connecting(.iceGathering)
        } catch {
            log.error("PiKVM connect failed: \(Self.describe(error), privacy: .public)")
            state = .failed(Self.describe(error))
            await teardown()
        }
    }

    public func disconnect() async {
        await teardown()
        state = .idle
    }

    public func markFirstFrameReceived() {
        if !hasReceivedFirstFrame {
            log.info("PiKVM first video frame rendered")
            hasReceivedFirstFrame = true
        }
    }

    // MARK: - Pumps

    private func startPumps(webrtc: WebRTCFacade, janus: JanusSignalingClient, events: PiKVMEventClient) {
        // Remote video track → UI.
        pumpTasks.append(Task { [weak self] in
            for await track in await webrtc.videoTracks {
                self?.videoRenderer = WebRTCVideoRenderer(track: track)
            }
        })

        // ICE connection state → session state.
        pumpTasks.append(Task { [weak self] in
            for await rtcState in await webrtc.connectionState {
                self?.handleRTCState(rtcState)
            }
        })

        // Local ICE candidates → Janus trickle.
        pumpTasks.append(Task {
            for await cand in await webrtc.localIceCandidates {
                await janus.sendTrickle(JanusCandidate(
                    candidate: cand.candidate,
                    sdpMid: cand.sdpMid,
                    sdpMLineIndex: cand.sdpMLineIndex.map(Int32.init)
                ))
            }
            await janus.sendTrickleCompleted()
        })

        // Remote ICE candidates the server trickles → peer connection.
        // (Many streaming setups embed candidates in the offer SDP and
        // never trickle, in which case this stream stays empty.)
        pumpTasks.append(Task {
            for await cand in await janus.remoteCandidates {
                guard let candStr = cand.candidate else { continue }
                let ice = IceCandidate(
                    candidate: candStr,
                    sdpMid: cand.sdpMid,
                    sdpMLineIndex: cand.sdpMLineIndex.map { UInt16(truncatingIfNeeded: $0) }
                )
                try? await webrtc.addRemoteIceCandidate(ice)
            }
        })

        // Connection-quality stats.
        pumpTasks.append(Task { [weak self] in
            for await sample in await webrtc.stats {
                self?.appendStatsSample(sample)
            }
        })

        // Inbound HID state → absolute/relative awareness.
        pumpTasks.append(Task { [weak self] in
            for await hid in await events.hidStates {
                if let abs = hid.mouse?.absolute { self?.mouseAbsolute = abs }
            }
        })
    }

    private func handleRTCState(_ rtcState: WebRTCConnectionState) {
        switch rtcState {
        case .connected:
            if state != .kicked { state = .connected }
        case .failed:
            state = .failed("WebRTC connection failed")
        case .closed:
            if case .connected = state { state = .failed("Connection closed") }
        case .disconnected, .new, .connecting:
            break
        }
    }

    private func appendStatsSample(_ sample: ConnectionStats) {
        latestStats = sample
        statsHistory.append(sample)
        let overshoot = statsHistory.count - Self.maxStatsHistory
        if overshoot > 0 { statsHistory.removeFirst(overshoot) }
    }

    // MARK: - Input

    public func sendKeypress(virtualKeyCode keyCode: UInt16, pressed: Bool) {
        guard isConnected, let code = WebKeyMap.virtualKeyToWebCode[keyCode] else { return }
        // Cmd-shortcut path: AppKit swallows keyUp for Cmd+<letter>, so
        // emit press+release atomically (mirrors the JetKVM backend).
        if pressed, !ModifierBits.anyMeta.intersection(modifierTracker.currentState).isEmpty {
            emit(try? PiKVMEvent.key(code: code, pressed: true))
            emit(try? PiKVMEvent.key(code: code, pressed: false))
            return
        }
        emit(try? PiKVMEvent.key(code: code, pressed: pressed))
    }

    public func handleFlagsChanged(virtualKeyCode keyCode: UInt16) {
        guard isConnected, let code = WebKeyMap.virtualKeyToWebCode[keyCode] else { return }

        // Caps Lock: macOS fires once per toggle; emit a momentary
        // press+release so the host flips its own lock state.
        if keyCode == 0x39 {
            emit(try? PiKVMEvent.key(code: code, pressed: true))
            emit(try? PiKVMEvent.key(code: code, pressed: false))
            return
        }

        guard let transition = modifierTracker.handle(modifierKeyCode: keyCode) else { return }
        if transition.pressed { heldModifierCodes.insert(code) } else { heldModifierCodes.remove(code) }
        emit(try? PiKVMEvent.key(code: code, pressed: transition.pressed))
    }

    public func releaseAllHeldModifiers() {
        for code in heldModifierCodes {
            emit(try? PiKVMEvent.key(code: code, pressed: false))
        }
        heldModifierCodes.removeAll()
        modifierTracker.reset()
    }

    public func sendPointerMotion(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons) {
        guard isConnected else { return }
        applyButtons(buttons)
        guard pointerThrottler.shouldEmit() else { return }
        emit(try? PiKVMEvent.mouseMove(
            x: PiKVMEvent.absoluteCoordinate(fromNormalized: normalizedX),
            y: PiKVMEvent.absoluteCoordinate(fromNormalized: normalizedY)
        ))
    }

    public func sendPointerButtonChange(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons) {
        guard isConnected else { return }
        pointerThrottler.reset()
        // Web client sends the planned move before the button transition.
        emit(try? PiKVMEvent.mouseMove(
            x: PiKVMEvent.absoluteCoordinate(fromNormalized: normalizedX),
            y: PiKVMEvent.absoluteCoordinate(fromNormalized: normalizedY)
        ))
        applyButtons(buttons)
    }

    public func sendMouseRelative(dx: Int8, dy: Int8, buttons: MouseButtons) {
        guard isConnected else { return }
        applyButtons(buttons)
        emit(try? PiKVMEvent.mouseRelative(dx: Int(dx), dy: Int(dy)))
    }

    public func sendWheelReport(wheelY: Int8, wheelX: Int8) {
        guard isConnected else { return }
        let dy = PiKVMEvent.wheelDelta(fromTick: Int(wheelY))
        let dx = PiKVMEvent.wheelDelta(fromTick: Int(wheelX))
        if dx == 0 && dy == 0 { return }
        emit(try? PiKVMEvent.mouseWheel(dx: dx, dy: dy))
    }

    public func pauseVideo() {}   // No encoder-pause control on PiKVM v1.
    public func resumeVideo() {}

    // MARK: - Input helpers

    /// Emit one `mouse_button` event per button whose pressed state
    /// changed since the last call.
    private func applyButtons(_ new: MouseButtons) {
        let changed = new.symmetricDifference(lastButtons)
        guard !changed.isEmpty else { return }
        for (bit, button) in Self.buttonMap where changed.contains(bit) {
            emit(try? PiKVMEvent.mouseButton(button, pressed: new.contains(bit)))
        }
        lastButtons = new
    }

    private func emit(_ data: Data?) {
        guard let data, let events else { return }
        Task { await events.send(data) }
    }

    private var isConnected: Bool {
        if case .connected = state { return true }
        // Allow input during iceGathering too (channel is up before the
        // RTC state flips to connected).
        if case .connecting(.iceGathering) = state { return true }
        return false
    }

    // MARK: - Teardown

    private func teardown() async {
        for task in pumpTasks { task.cancel() }
        pumpTasks = []
        if let webrtc { await webrtc.close() }
        if let janus { await janus.disconnect() }
        if let events { await events.disconnect() }
        webrtc = nil
        janus = nil
        events = nil
        http = nil
        videoRenderer?.detach()
        videoRenderer = nil
        hasReceivedFirstFrame = false
        latestStats = nil
        statsHistory = []
        modifierTracker.reset()
        pointerThrottler.reset()
        heldModifierCodes.removeAll()
        lastButtons = []
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? HTTPClientError { return "HTTP: \(e)" }
        if let e = error as? PiKVMTransportError { return "PiKVM: \(e)" }
        return "\(error)"
    }
}
