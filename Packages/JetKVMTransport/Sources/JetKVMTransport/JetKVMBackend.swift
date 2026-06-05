import Foundation
import JetKVMProtocol
import Observation
import OSLog
import WebRTC

private let log = Logger(subsystem: "app.regi.mac", category: "session")

public enum SessionError: Error, Sendable {
    /// `GET /device/status` returned `isSetup: false`. The device hasn't
    /// been provisioned yet — we don't try to push past this; the user
    /// has to go through the setup flow in the web UI first.
    case deviceNotProvisioned
    /// Server sent device-metadata with an empty deviceVersion, indicating
    /// firmware too old for the WS signaling path (per the plan).
    case deviceTooOld
    /// The signaling WS sent something other than device-metadata first.
    case unexpectedFirstMessage(String)
    /// Tried to make an RPC call before the rpc data channel opened.
    case rpcNotReady
    case underlying(Error)
}

/// JetKVM transport backend: orchestrates the connect flow — HTTP auth →
/// signaling WS → WebRTC peer connection — and owns one HTTPClient,
/// SignalingClient, and WebRTCFacade for the lifetime of a connection.
/// Drives input over binary HID-RPC data channels and the control plane
/// over JSON-RPC. Reached through the `Session` façade, which picks this
/// backend for `DeviceKind.jetKVM`.
///
/// `@MainActor` so SwiftUI can observe state directly (through the
/// façade) without an extra view-model translation layer. The underlying
/// transports are themselves actors so heavy work doesn't block the main
/// thread.
@MainActor
@Observable
public final class JetKVMBackend: KVMBackend {
    /// Shared connection-state vocabulary. `Session.State` is a
    /// typealias to the same `KVMState`, so the App layer's switches
    /// work unchanged.
    public typealias State = KVMState

    /// JetKVM exposes the full control-plane feature set.
    public let capabilities: KVMCapabilities = .jetKVM

    public private(set) var state: State = .idle
    public private(set) var deviceMetadata: DeviceMetadata?
    public private(set) var device: LocalDevice?
    public private(set) var videoTrack: RTCVideoTrack?
    /// Distinct from `videoTrack != nil` — the track is attached
    /// during SDP negotiation (well before frames flow), but actual
    /// pixels can lag by hundreds of ms. The KVMVideoView renderer
    /// fires `didChangeVideoSize` when the first non-zero-dim frame
    /// lands; that's our signal that the user is about to see
    /// something. Used by KVMSessionWindow to keep the connect-flow
    /// overlay up across the gap.
    public private(set) var hasReceivedFirstFrame: Bool = false
    /// `true` once the reliable HID-RPC channel is open and the
    /// handshake has been sent. Input handlers should gate on this so
    /// keypress/pointer reports aren't silently dropped server-side
    /// (`hidrpc.go:28`).
    public private(set) var hidReady: Bool = false
    /// `true` once the `rpc` data channel is open. Typed RPC methods
    /// should gate on this so calls don't hang waiting for a
    /// response that can't ride a closed channel.
    public private(set) var rpcReady: Bool = false
    /// The JSON-RPC 2.0 client over the `rpc` data channel. Available
    /// once the connection is up; nil before connect / after disconnect.
    public private(set) var rpc: JSONRPCClient?

    // MARK: - Cached control-plane state
    //
    // Populated on rpc-ready by a one-shot `refreshControlState()`
    // call, and updated optimistically when the user changes a value
    // via setStreamQualityFactor / setVideoCodecPreference. Server-
    // pushed events (M3 commit 18) refresh the time-varying ones
    // (videoState, usbState, atxState).

    public internal(set) var videoState: VideoState?
    public internal(set) var usbState: String?
    public internal(set) var atxState: ATXState?
    public internal(set) var streamQualityFactor: Double?
    public internal(set) var videoCodecPreference: VideoCodecPreference?
    /// Last-received failsafe mode notification. nil when the device
    /// hasn't sent one yet; `.active == true` is the signal that the
    /// device is in failsafe mode and the UI should warn the user.
    public internal(set) var failsafe: FailsafeModeNotification?
    /// Presence of a host-side clipboard agent on the connected
    /// JetKVM. Driven by the `clipboardAgentStateChanged` push
    /// notification + a bootstrap `getClipboardAgentState` RPC at
    /// rpc-ready. `.absent` until proven otherwise.
    public internal(set) var clipboardAgentState: ClipboardAgentState = .absent
    /// Wire-protocol bridge for the `host_bridge` data channel.
    /// Constructed on connect; nil between sessions. The App layer
    /// injects a `ClipboardSource` (NSPasteboard-backed) into
    /// `clipboardBridge?.source` so it can ship and receive offers.
    public private(set) var clipboardBridge: ClipboardBridge?

    /// Most recent connection-quality sample. Updated ~1 Hz once the
    /// peer connection is up.
    public private(set) var latestStats: ConnectionStats?
    /// Rolling window of recent samples, oldest first. Drives
    /// sparkline rendering. Capped at `maxStatsHistory` samples.
    public private(set) var statsHistory: [ConnectionStats] = []
    public static let maxStatsHistory = 60

    /// Minimum JetKVM firmware version that dispatches the binary
    /// `wheelReport` opcode (0x04) over the HID-RPC channel. Older
    /// firmware silently drops unknown opcodes, so the JSON-RPC
    /// `wheelReport` method is used below this version.
    public static let binaryWheelMinVersion = "0.5.9"

    private var endpoint: DeviceEndpoint?
    private var http: HTTPClient?
    private var signaling: SignalingClient?
    private var webrtc: WebRTCFacade?
    private var pumpTasks: [Task<Void, Never>] = []
    private var modifierTracker = ModifierTracker()
    private var pointerThrottler = InputThrottler(interval: .milliseconds(8))
    /// USB-HID Usage IDs of non-modifier keys we believe are held on
    /// the host. Combined with `modifierTracker.currentState` it tells
    /// the keep-alive loop whether to fire a heartbeat.
    private var heldNonModifierKeys: Set<UInt8> = []

    // Reconnect state. Transitions:
    //   user-initiated connect()        → reset all four
    //   reach .connected (any attempt)  → reset reconnectAttempt to 0,
    //                                     mark hasBeenConnectedThisSession
    //   ICE drops .failed / .closed     → if hasBeenConnectedThisSession,
    //                                     bump attempt + scheduleReconnect()
    //   user-initiated disconnect()     → cancel reconnectTask, clear all
    private var lastEndpoint: DeviceEndpoint?
    private var lastPassword: String?
    private var reconnectAttempt: Int = 0
    private var reconnectTask: Task<Void, Never>?
    private var hasBeenConnectedThisSession: Bool = false

    public init() {}

    // MARK: - Public API

    /// Begin connecting to a device. If the device is in password mode and
    /// no password is supplied (or the supplied one is wrong), the state
    /// transitions to `.awaitingPassword`; the UI is expected to collect a
    /// password and call `connect(...)` again with it.
    public func connect(endpoint: DeviceEndpoint, password: String? = nil) async {
        if case .connecting = state { return }
        log.info("connect → \(endpoint.host, privacy: .public):\(endpoint.port, privacy: .public) tls=\(endpoint.useTLS, privacy: .public)")
        // User-initiated connect — reset the reconnect state machine
        // so we don't carry over a previous failure's attempt count
        // or pending retry timer.
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        hasBeenConnectedThisSession = false
        lastEndpoint = endpoint
        lastPassword = password
        await teardown()

        self.endpoint = endpoint
        state = .connecting(.checkingStatus)

        let http = HTTPClient(endpoint: endpoint)
        self.http = http

        do {
            // 1. Public status check.
            let status = try await http.getDeviceStatus()
            guard status.isSetup else {
                log.notice("device /device/status reports isSetup=false")
                state = .failed("Device not provisioned. Open the web UI to set it up first.")
                return
            }

            // 2. Try /device. In noPassword mode this works without auth
            //    (web.go:561-577 lets unauthenticated requests through).
            //    In password mode it 401s and we either log in or stop to
            //    ask the user.
            state = .connecting(.authenticating)
            let device: LocalDevice
            do {
                device = try await http.getDevice()
            } catch HTTPClientError.unauthorized {
                if let password {
                    do {
                        try await http.login(password: password)
                    } catch HTTPClientError.unauthorized(let msg) {
                        log.notice("login rejected: \(msg ?? "<no message>", privacy: .public)")
                        state = .awaitingPassword(self.device)
                        return
                    }
                    device = try await http.getDevice()
                } else {
                    log.info("/device 401 with no password supplied → awaiting password from UI")
                    state = .awaitingPassword(nil)
                    return
                }
            }
            self.device = device

            // 3. Open signaling WS, replaying the auth cookie HTTPClient
            //    captured from the login response so the upgrade request
            //    carries it.
            state = .connecting(.signaling)
            let signaling = SignalingClient(
                endpoint: endpoint,
                cookieStorage: http.cookieStorage
            )
            self.signaling = signaling
            let (metadata, incoming) = try await signaling.connect()
            guard !metadata.deviceVersion.isEmpty else {
                throw SessionError.deviceTooOld
            }
            self.deviceMetadata = metadata

            // 4. Stand up the WebRTC peer connection, the JSON-RPC
            //    client over its rpc channel, and the pumps.
            let webrtc = WebRTCFacade()
            self.webrtc = webrtc
            let rpcClient = JSONRPCClient(send: { [weak webrtc] frame in
                guard let webrtc else { return false }
                return await webrtc.sendRPCFrame(frame)
            })
            self.rpc = rpcClient
            startPumps(webrtc: webrtc, signaling: signaling, incoming: incoming, rpc: rpcClient)

            // 5. Build offer and ship it.
            state = .connecting(.offering)
            let offerSDP = try await webrtc.start()
            try await signaling.send(.offer(sdpBase64: offerSDP))
            state = .connecting(.awaitingAnswer)
        } catch HTTPClientError.untrustedServerCertificate(let reason) {
            log.notice("TLS trust failed for \(endpoint.host, privacy: .public): \(reason, privacy: .public) — awaiting user opt-in")
            // Don't auto-retry here even if reconnectAttempt > 0 — a
            // mid-session cert flip should still surface to the user
            // rather than silently get backed off.
            state = .awaitingTrustOverride(host: endpoint.host, reason: reason)
            await teardown()
        } catch {
            log.error("connect failed: \(describe(error), privacy: .public)")
            // If this attempt was part of a reconnect cycle, bump the
            // attempt counter and schedule another retry instead of
            // declaring terminal failure. Fresh user-initiated
            // connects (reconnectAttempt == 0) go to .failed so the UI
            // prompts the user to retry manually.
            if reconnectAttempt > 0 {
                await teardown()
                scheduleReconnect()
            } else {
                state = .failed(describe(error))
                await teardown()
            }
        }
    }

    public func disconnect() async {
        log.info("disconnect")
        // Cancel any pending reconnect attempt and clear the saved
        // endpoint/password so a stale timer can't fire after the
        // user has explicitly bailed.
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        hasBeenConnectedThisSession = false
        lastEndpoint = nil
        lastPassword = nil
        await teardown()
        state = .idle
    }

    // MARK: - Input

    /// Forward a `keyDown` or `keyUp` event from the KVM view. The
    /// `keyCode` is the macOS Carbon virtual keycode
    /// (`NSEvent.keyCode`); we translate via `KeyMap`.
    /// Drops if the HID channel isn't ready yet, or if the keyCode
    /// isn't in the keymap.
    public func sendKeypress(virtualKeyCode keyCode: UInt16, pressed: Bool) {
        guard hidReady, let webrtc else { return }
        guard let usbHID = KeyMap.virtualKeyToHIDUsageID[keyCode] else { return }

        // Cmd-shortcut path: AppKit doesn't deliver keyUp for keys
        // pressed while Cmd is held — the menu-shortcut routing
        // swallows it. If we treated this as a regular press and
        // tracked it in `heldNonModifierKeys`, the host would see the
        // key held until Cmd is released, which trips its own
        // key-repeat (e.g. multiple Cmd+C invocations from one tap).
        // Without CGEventTap-based capture this is unavoidable, so
        // emit press+release atomically: the host sees a brief tap
        // regardless of how long the user holds the key. Don't track
        // in `heldNonModifierKeys` — there's no real "held" state.
        if pressed, !ModifierBits.anyMeta.intersection(modifierTracker.currentState).isEmpty {
            let down = HIDRPCMessage.keypressReport(key: usbHID, pressed: true)
            let up = HIDRPCMessage.keypressReport(key: usbHID, pressed: false)
            Task {
                await webrtc.sendHID(down, on: .reliable)
                await webrtc.sendHID(up, on: .reliable)
            }
            return
        }

        if pressed {
            heldNonModifierKeys.insert(usbHID)
        } else {
            heldNonModifierKeys.remove(usbHID)
        }
        let message = HIDRPCMessage.keypressReport(key: usbHID, pressed: pressed)
        Task { await webrtc.sendHID(message, on: .reliable) }
    }

    /// Forward a `flagsChanged` event from the KVM view. Two distinct
    /// cases:
    ///
    /// - **Held modifiers** (Shift, Cmd, Option, Control). macOS fires
    ///   `flagsChanged` on press *and* on release, so we let
    ///   `ModifierTracker` toggle its internal state and emit one
    ///   `KeypressReport` per transition with the modifier-key USB-HID
    ///   code (0xE0..0xE7).
    /// - **Caps Lock**. macOS treats it as a toggle and fires
    ///   `flagsChanged` once per physical press, with the new toggle
    ///   state in `modifierFlags`. The host (USB HID) wants a
    ///   momentary press to flip its own CapsLock state, so we emit
    ///   press + release back-to-back. Looking up via `KeyMap`
    ///   (kVK_CapsLock 0x39 → USB HID 0x39).
    public func handleFlagsChanged(virtualKeyCode keyCode: UInt16) {
        guard hidReady, let webrtc else { return }

        if keyCode == 0x39, let usbHID = KeyMap.virtualKeyToHIDUsageID[keyCode] {
            // Caps Lock toggle. macOS hosts apply a debounce/minimum-hold
            // duration to USB-HID Caps Lock (anti-accident, since Sierra),
            // so a back-to-back press+release is rejected as a glitch.
            // Holding for ~200ms clears the threshold on macOS hosts
            // tested without being noticeably laggy. Linux/Windows hosts
            // toggle on the release regardless of duration, so this is
            // safe across hosts.
            let down = HIDRPCMessage.keypressReport(key: usbHID, pressed: true)
            let up = HIDRPCMessage.keypressReport(key: usbHID, pressed: false)
            Task {
                await webrtc.sendHID(down, on: .reliable)
                try? await Task.sleep(for: .milliseconds(200))
                await webrtc.sendHID(up, on: .reliable)
            }
            return
        }

        guard let transition = modifierTracker.handle(modifierKeyCode: keyCode) else { return }
        guard let usbHID = transition.modifier.usbHIDUsageID else { return }
        let message = HIDRPCMessage.keypressReport(key: usbHID, pressed: transition.pressed)
        Task { await webrtc.sendHID(message, on: .reliable) }

        // Without CGEventTap-based capture, AppKit swallows the keyUp
        // for Cmd+<letter> shortcuts that match a menu item (Cmd+C,
        // Cmd+V, Cmd+W, …), so `heldNonModifierKeys` accumulates a
        // phantom hold for the letter. The keepalive heartbeat keeps
        // the gadget driver from auto-releasing it on the host, so
        // the host sees the letter pressed indefinitely and the OS
        // key-repeat fires forever. Sweep those holds when Cmd is
        // released — the user finishing the shortcut is our cue that
        // any non-modifier we still think is down was almost certainly
        // already up on the local side.
        if !transition.pressed,
           ModifierBits.anyMeta.contains(transition.modifier),
           !heldNonModifierKeys.isEmpty {
            let stuck = heldNonModifierKeys
            heldNonModifierKeys.removeAll()
            Task {
                for key in stuck {
                    let release = HIDRPCMessage.keypressReport(key: key, pressed: false)
                    await webrtc.sendHID(release, on: .reliable)
                }
            }
        }
    }

    /// Release every modifier the tracker thinks is held on the host
    /// side, then reset the tracker. Call when capture pauses (e.g.
    /// our app lost focus mid-keystroke) so the host doesn't end up
    /// with stuck modifiers we'll never explicitly release.
    public func releaseAllHeldModifiers() {
        guard let webrtc else {
            modifierTracker.reset()
            heldNonModifierKeys.removeAll()
            return
        }
        let allBits: [ModifierBits] = [
            .leftControl, .leftShift, .leftAlt, .leftMeta,
            .rightControl, .rightShift, .rightAlt, .rightMeta,
        ]
        let held = modifierTracker.currentState
        for bit in allBits where held.contains(bit) {
            guard let usbHID = bit.usbHIDUsageID else { continue }
            let message = HIDRPCMessage.keypressReport(key: usbHID, pressed: false)
            if hidReady {
                Task { await webrtc.sendHID(message, on: .reliable) }
            }
        }
        modifierTracker.reset()
        // Note: heldNonModifierKeys are intentionally NOT released
        // here — onSuspend fires only on focus loss while in capture
        // mode, which is a "modifiers might be stuck" failure mode
        // specific to held-mid-keystroke modifiers. Regular keys
        // surfaced via NSView keyUp on focus return.
        heldNonModifierKeys.removeAll()
    }

    /// Forward continuous mouse motion (mouseMoved / mouseDragged).
    /// Throttled to ~120 Hz at the InputThrottler — under congestion,
    /// dropping a stale absolute position is better than queueing it.
    public func sendPointerMotion(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons) {
        guard hidReady else { return }
        guard pointerThrottler.shouldEmit() else { return }
        sendPointerReport(x: normalizedX, y: normalizedY, buttons: buttons)
    }

    /// Forward a discrete mouse-button transition (mouseDown / mouseUp
    /// for left/right/middle/back/forward). Bypasses the throttler so
    /// down/up pairs always reach the host even if a motion event was
    /// just throttled out, and resets the throttler so the next motion
    /// event doesn't get dropped immediately after a click.
    public func sendPointerButtonChange(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons) {
        guard hidReady else { return }
        pointerThrottler.reset()
        sendPointerReport(x: normalizedX, y: normalizedY, buttons: buttons)
    }

    private func sendPointerReport(x: Int32, y: Int32, buttons: MouseButtons) {
        guard let webrtc else { return }
        let message = HIDRPCMessage.pointerReport(x: x, y: y, buttons: buttons.rawValue)
        Task { await webrtc.sendHID(message, on: .unreliableOrdered) }
    }

    /// Forward a relative-mouse event when pointer-lock is engaged.
    /// `dx` / `dy` are signed bytes — clamp at the call site if the
    /// underlying NSEvent delta exceeds Int8 range. `buttons` is the
    /// current pressed-buttons bitmask (0 for pure motion, the
    /// active button bit for drag, 0 again for release).
    public func sendMouseRelative(dx: Int8, dy: Int8, buttons: MouseButtons) {
        guard hidReady, let webrtc else { return }
        let message = HIDRPCMessage.mouseReport(dx: dx, dy: dy, buttons: buttons.rawValue)
        Task { await webrtc.sendHID(message, on: .unreliableOrdered) }
    }

    /// Tell the device to stop pushing video frames to the WebRTC
    /// track. RTP drops to keepalive levels until `resumeVideo()`
    /// is called. The data channels (rpc, hidrpc) stay open so
    /// input forwarding still works through the pause. Fire-and-
    /// forget; idempotent server-side. Used by the App layer to
    /// save bandwidth when the KVM window is occluded / minimized.
    public func pauseVideo() {
        guard rpcReady else { return }
        Task { [weak self] in
            do {
                try await self?.pauseVideoRPC()
            } catch {
                log.error("pauseVideo failed: \(describe(error), privacy: .public)")
            }
        }
    }

    /// Resume video frame delivery after `pauseVideo()`. The server
    /// forces an IDR before the next sample so the decoder never
    /// sees a P-frame referencing a dropped reference. Fire-and-
    /// forget; idempotent server-side.
    public func resumeVideo() {
        guard rpcReady else { return }
        Task { [weak self] in
            do {
                try await self?.resumeVideoRPC()
            } catch {
                log.error("resumeVideo failed: \(describe(error), privacy: .public)")
            }
        }
    }

    /// Forward a scroll-wheel event. Routes through the binary
    /// `wheelReport` opcode (0x04) on the unreliable-ordered HID
    /// channel when the firmware is recent enough to dispatch it
    /// (saves ~70 bytes/event vs JSON-RPC, drops the per-event JSON
    /// parse on the device, and rides the drop-tolerant channel mouse
    /// motion uses). Falls back to the JSON-RPC `wheelReport` method
    /// on older firmware.
    ///
    /// Gating is by firmware version (>= 0.5.9 ships the binary
    /// dispatch handler) rather than a runtime capability
    /// advertisement — no opcode-list field exists in the
    /// `device-metadata` payload and there's no plan to add one
    /// upstream. Fire-and-forget; failures are logged but not
    /// propagated, matching sendKeypress / sendPointer semantics so
    /// call sites don't have to await.
    public func sendWheelReport(wheelY: Int8, wheelX: Int8) {
        if wheelY == 0 && wheelX == 0 { return }
        let useBinary = deviceMetadata?.firmwareIsAtLeast(Self.binaryWheelMinVersion) == true
        if useBinary {
            guard hidReady, let webrtc else { return }
            let message = HIDRPCMessage.wheelReport(deltaY: wheelY, deltaX: wheelX)
            Task { await webrtc.sendHID(message, on: .unreliableOrdered) }
        } else {
            guard rpcReady else { return }
            Task { [weak self] in
                do {
                    try await self?.sendWheelReportRPC(wheelY: wheelY, wheelX: wheelX)
                } catch {
                    log.error("wheelReport(y=\(wheelY, privacy: .public), x=\(wheelX, privacy: .public)) failed: \(describe(error), privacy: .public)")
                }
            }
        }
    }

    // MARK: - Internal pumps

    private func startPumps(
        webrtc: WebRTCFacade,
        signaling: SignalingClient,
        incoming: AsyncThrowingStream<SignalingMessage, Error>,
        rpc: JSONRPCClient
    ) {
        // 0. Stand up the clipboard bridge. Lives for the session
        //    lifetime; the App layer wires a NSPasteboard-backed
        //    `ClipboardSource` into `bridge.source` and consumes
        //    `bridge.inboundOffers`. The closure captures `webrtc`
        //    weakly so we don't keep the facade alive past teardown.
        let bridge = ClipboardBridge { [weak webrtc] data in
            guard let webrtc else { return false }
            return await webrtc.sendHostBridge(data)
        }
        self.clipboardBridge = bridge
        // 1. Server → us: answers and ICE candidates from signaling stream.
        pumpTasks.append(Task { [weak self] in
            do {
                for try await message in incoming {
                    guard let self else { return }
                    switch message {
                    case .answer(let sdpBase64):
                        try await webrtc.setRemoteAnswer(sdpBase64: sdpBase64)
                        await self.transition(.connecting(.iceGathering))
                    case .newIceCandidate(let cand):
                        try await webrtc.addRemoteIceCandidate(cand)
                    case .deviceMetadata, .offer:
                        // Server doesn't normally re-send these.
                        continue
                    }
                }
            } catch {
                log.error("signaling pump terminated: \(describe(error), privacy: .public)")
                await self?.fail(describe(error))
            }
        })

        // 2. Us → server: locally-gathered ICE candidates.
        pumpTasks.append(Task { [weak self] in
            for await candidate in await webrtc.localIceCandidates {
                guard self != nil else { return }
                try? await signaling.send(.newIceCandidate(candidate))
            }
        })

        // 3. Surface remote video tracks to the UI.
        pumpTasks.append(Task { [weak self] in
            for await track in await webrtc.videoTracks {
                guard let self else { return }
                await self.attachVideoTrack(track)
            }
        })

        // 4. Watch ICE connection state; flip to .connected on first success.
        pumpTasks.append(Task { [weak self] in
            for await rtcState in await webrtc.connectionState {
                guard let self else { return }
                await self.handleRTCState(rtcState)
            }
        })

        // 5. Track when the reliable HID channel is open + handshaken.
        pumpTasks.append(Task { @MainActor [weak self] in
            for await ready in await webrtc.hidReadyState {
                self?.hidReady = ready
                if !ready {
                    self?.modifierTracker.reset()
                }
            }
        })

        // 6. Pump rpc text frames into the JSON-RPC client.
        pumpTasks.append(Task {
            for await frame in await webrtc.incomingRPCFrames {
                await rpc.handle(incomingFrame: frame)
            }
        })

        // 7. Track rpc channel open/closed state. On the first transition
        //    to ready, fetch the initial control-plane state so the UI
        //    has something to bind to before any server events arrive.
        pumpTasks.append(Task { @MainActor [weak self] in
            for await ready in await webrtc.rpcReadyState {
                self?.rpcReady = ready
                if ready {
                    await self?.refreshControlState()
                }
            }
        })

        // 8. Server-pushed JSON-RPC notifications. The server fires
        //    these without prompting (`webrtc.go:406-411` etc.) — most
        //    update the cached control-plane state, otherSessionConnected
        //    transitions us to `.kicked`.
        pumpTasks.append(Task { @MainActor [weak self] in
            for await notification in await rpc.notifications {
                self?.handleRPCNotification(notification)
            }
        })

        // 9. host_bridge channel pumps — feed the clipboard bridge.
        //    Ready-state drives the Hello handshake; binary frames are
        //    the wire-protocol envelopes the bridge decodes.
        pumpTasks.append(Task { @MainActor [weak self] in
            for await ready in await webrtc.hostBridgeReadyState {
                await self?.clipboardBridge?.handleChannelReadyChange(ready)
            }
        })
        pumpTasks.append(Task { @MainActor [weak self] in
            for await frame in await webrtc.incomingHostBridgeFrames {
                await self?.clipboardBridge?.handleInboundFrame(frame)
            }
        })

        // 10. Connection-quality sampler. Drives the live FPS/RTT in
        //    the status strip and the Stats panel sparklines.
        pumpTasks.append(Task { @MainActor [weak self] in
            for await sample in await webrtc.stats {
                self?.appendStatsSample(sample)
            }
        })

        // 11. KeypressKeepAlive heartbeat — fires every 50ms on the
        //     reliable HID channel for as long as any key is held.
        //     The JetKVM gadget driver auto-releases held keys after
        //     ~100ms of no HID traffic; the keep-alive fills any gap
        //     in repeat events so e.g. Shift+drag doesn't release the
        //     modifier after a few seconds. Mirrors the TS UI's
        //     KEEPALIVE_INTERVAL constant in useKeyboard.ts.
        pumpTasks.append(Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                if self.anyKeyHeld, self.hidReady, let webrtc = self.webrtc {
                    await webrtc.sendHID(.keypressKeepAliveReport, on: .reliable)
                }
            }
        })
    }

    /// True when at least one key (modifier or regular) is reported
    /// to the host as held. The keep-alive heartbeat runs only while
    /// this is true.
    private var anyKeyHeld: Bool {
        !heldNonModifierKeys.isEmpty || !modifierTracker.currentState.isEmpty
    }

    private func appendStatsSample(_ sample: ConnectionStats) {
        latestStats = sample
        statsHistory.append(sample)
        let overshoot = statsHistory.count - Self.maxStatsHistory
        if overshoot > 0 {
            statsHistory.removeFirst(overshoot)
        }
    }

    private func handleRPCNotification(_ n: JSONRPCNotification) {
        // Important: only assign on decode success. `try?` here
        // would clobber existing state with nil on the first
        // payload-shape mismatch.
        switch n.method {
        case "otherSessionConnected":
            // Server sends this just before tearing down our peer
            // connection (cloud.go:477, web.go:261). Show the kicked
            // UI; .closed transitions stop overriding state.kicked
            // (see handleRTCState).
            state = .kicked

        case "videoInputState":
            if let v = try? n.decodeParams(VideoState.self) {
                videoState = v
            }

        case "usbState":
            // Wire shape is a bare JSON string ("configured",
            // "connected", "disconnected", …).
            if let s = try? n.decodeParams(String.self) {
                usbState = s
            }

        case "atxState":
            if let a = try? n.decodeParams(ATXState.self) {
                atxState = a
            }

        case "failsafeMode":
            if let f = try? n.decodeParams(FailsafeModeNotification.self) {
                failsafe = f
            }

        case "clipboardAgentStateChanged":
            // Wire shape: `{ "state": "absent" | "active" }` (see firmware
            // clipboard.go:125). Drop the notification on shape or value
            // mismatch rather than clobber state with .absent.
            struct Payload: Decodable { let state: String }
            do {
                let p = try n.decodeParams(Payload.self)
                if let s = ClipboardAgentState(rawValue: p.state) {
                    let before = clipboardAgentState
                    clipboardAgentState = s
                    log.info("[SESSION] clipboardAgentStateChanged: \(before.rawValue, privacy: .public) → \(s.rawValue, privacy: .public)")
                } else {
                    log.error("[SESSION] clipboardAgentStateChanged: unknown state '\(p.state, privacy: .public)'; ignoring")
                }
            } catch {
                log.error("[SESSION] clipboardAgentStateChanged decode failed: \(String(describing: error), privacy: .public)")
            }

        default:
            // Unhandled events (otaState, networkState, dcState,
            // willReboot, keyboardLedState, etc.) — silently ignore
            // for now; surface them when a feature actually needs
            // them.
            break
        }
    }

    private func attachVideoTrack(_ track: RTCVideoTrack) {
        videoTrack = track
    }

    /// Called by KVMVideoView when its `RTCVideoViewDelegate` reports
    /// a non-zero video size — i.e. frames have actually started
    /// rendering. Public so the App layer can call into us; idempotent.
    public func markFirstFrameReceived() {
        if !hasReceivedFirstFrame {
            log.info("first video frame rendered")
            hasReceivedFirstFrame = true
        }
    }

    private func transition(_ new: State) {
        state = new
    }

    private func handleRTCState(_ rtcState: WebRTCConnectionState) {
        switch rtcState {
        case .connected:
            // Don't trample .kicked — that takes precedence visually
            // even if the underlying RTC state is technically still
            // connected for the second or so before the server tears
            // us down.
            if state != .kicked {
                state = .connected
                hasBeenConnectedThisSession = true
                reconnectAttempt = 0
            }
        case .failed:
            // ICE giving up after retry. If we were ever connected
            // this session, treat it as transient and reconnect with
            // backoff. If we never made it (initial-connect ICE
            // failure), surface as terminal so the user can intervene.
            if hasBeenConnectedThisSession {
                scheduleReconnect()
            } else if reconnectAttempt > 0 {
                // Reconnect-time ICE failure on a session that never
                // re-established → keep retrying.
                scheduleReconnect()
            } else {
                state = .failed("WebRTC connection failed")
            }
        case .closed:
            // Closure may be initiated by us or by the server (e.g.
            // after otherSessionConnected). When we're already
            // .kicked, stay there so the user sees the kicked UI.
            // When we were .connected, this is an unexpected mid-
            // session drop — auto-reconnect.
            if case .connected = state {
                scheduleReconnect()
            }
        case .disconnected:
            // Transient — WebRTC may recover. Don't change state.
            break
        case .new, .connecting:
            break
        }
    }

    /// Schedule the next reconnect attempt with exponential backoff
    /// (1, 2, 4, 8, 16, capped at 30 seconds). The `reconnectAttempt`
    /// counter persists across the cycle and only resets on
    /// .connected or user-initiated connect/disconnect.
    private func scheduleReconnect() {
        guard let endpoint = lastEndpoint else { return }
        reconnectAttempt += 1
        let backoffSeconds = min(30, 1 << min(reconnectAttempt - 1, 4))  // 1, 2, 4, 8, 16, 30, 30, …
        log.info("scheduling reconnect attempt \(self.reconnectAttempt, privacy: .public) in \(backoffSeconds, privacy: .public)s")
        state = .reconnecting(attempt: reconnectAttempt)

        reconnectTask?.cancel()
        let savedPassword = lastPassword
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(backoffSeconds))
            guard let self, !Task.isCancelled else { return }
            // Run the connect flow again with the same endpoint /
            // password. The retry path falls through the same connect
            // logic; on failure it loops back here via the catch
            // branch in connect().
            log.info("reconnect attempt \(self.reconnectAttempt, privacy: .public) firing")
            await self.performReconnect(endpoint: endpoint, password: savedPassword)
        }
    }

    private func performReconnect(endpoint: DeviceEndpoint, password: String?) async {
        // Manually run the body of connect() WITHOUT the user-
        // initiated reset, so reconnectAttempt and lastEndpoint stay
        // intact across iterations of the cycle.
        await teardown()
        self.endpoint = endpoint
        state = .connecting(.checkingStatus)
        let http = HTTPClient(endpoint: endpoint)
        self.http = http
        do {
            let status = try await http.getDeviceStatus()
            guard status.isSetup else {
                state = .failed("Device not provisioned. Open the web UI to set it up first.")
                return
            }
            state = .connecting(.authenticating)
            let device: LocalDevice
            do {
                device = try await http.getDevice()
            } catch HTTPClientError.unauthorized {
                if let password {
                    do {
                        try await http.login(password: password)
                    } catch HTTPClientError.unauthorized {
                        // Saved password no longer works — fall back
                        // to terminal awaitingPassword so the user can
                        // retype.
                        state = .awaitingPassword(self.device)
                        return
                    }
                    device = try await http.getDevice()
                } else {
                    state = .awaitingPassword(nil)
                    return
                }
            }
            self.device = device
            state = .connecting(.signaling)
            let signaling = SignalingClient(
                endpoint: endpoint,
                cookieStorage: http.cookieStorage
            )
            self.signaling = signaling
            let (metadata, incoming) = try await signaling.connect()
            guard !metadata.deviceVersion.isEmpty else {
                throw SessionError.deviceTooOld
            }
            self.deviceMetadata = metadata
            let webrtc = WebRTCFacade()
            self.webrtc = webrtc
            let rpcClient = JSONRPCClient(send: { [weak webrtc] frame in
                guard let webrtc else { return false }
                return await webrtc.sendRPCFrame(frame)
            })
            self.rpc = rpcClient
            startPumps(webrtc: webrtc, signaling: signaling, incoming: incoming, rpc: rpcClient)
            state = .connecting(.offering)
            let offerSDP = try await webrtc.start()
            try await signaling.send(.offer(sdpBase64: offerSDP))
            state = .connecting(.awaitingAnswer)
        } catch {
            log.error("reconnect attempt \(self.reconnectAttempt, privacy: .public) failed: \(describe(error), privacy: .public)")
            await teardown()
            scheduleReconnect()
        }
    }

    private func fail(_ message: String) async {
        state = .failed(message)
        await teardown()
    }

    private func teardown() async {
        for task in pumpTasks { task.cancel() }
        pumpTasks = []
        if let rpc = self.rpc {
            await rpc.close()
        }
        if let webrtc = self.webrtc {
            await webrtc.close()
        }
        if let signaling = self.signaling {
            await signaling.disconnect()
        }
        rpc = nil
        webrtc = nil
        signaling = nil
        http = nil
        videoTrack = nil
        hasReceivedFirstFrame = false
        hidReady = false
        rpcReady = false
        videoState = nil
        usbState = nil
        atxState = nil
        streamQualityFactor = nil
        videoCodecPreference = nil
        failsafe = nil
        clipboardAgentState = .absent
        clipboardBridge = nil
        latestStats = nil
        statsHistory = []
        modifierTracker.reset()
        pointerThrottler.reset()
        heldNonModifierKeys.removeAll()
    }
}

private func describe(_ error: Error) -> String {
    if let httpError = error as? HTTPClientError {
        return "HTTP: \(httpError)"
    }
    if let signalErr = error as? SignalingError {
        return "Signaling: \(signalErr)"
    }
    if let sessionErr = error as? SessionError {
        return "Session: \(sessionErr)"
    }
    return "\(error)"
}
