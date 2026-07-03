import Foundation
import JetKVMProtocol
import Observation
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "session")

/// Device-agnostic session façade the App layer binds to. Holds the
/// active `KVMBackend` (selected by `DeviceKind`) and forwards reads and
/// input to it. Kept as a single concrete `@Observable` type — rather
/// than exposing the backend protocol directly — because SwiftUI's
/// Observation tracks concrete `@Observable` types, not protocol
/// existentials; reads of `backend.state` etc. through these computed
/// properties are still tracked transitively because the concrete
/// backends are themselves `@Observable`.
///
/// JetKVM-only control-plane surface (codec/quality/ATX/clipboard) is
/// resolved by down-casting to `JetKVMBackend`; on other backends those
/// reads return neutral defaults and the App layer hides the
/// corresponding UI via `capabilities`.
@MainActor
@Observable
public final class Session {
    /// Shared connection-state vocabulary. Kept as `Session.State` so
    /// existing App-layer references (`Session.State.Phase`, the
    /// `session.state` switches) compile unchanged.
    public typealias State = KVMState

    /// The live backend for the current/last connection. Reassigned
    /// when connecting to a different device kind; reused across
    /// reconnects and password retries for the same kind.
    private var backend: (any KVMBackend)?

    public init() {}

    // MARK: - Observable state (forwarded)

    public var state: State { backend?.state ?? .idle }
    /// The renderer for the live video — a WebRTC renderer (JetKVM, PiKVM) or a
    /// local one (VNC), built by the active backend. Nil before video arrives.
    /// The view embeds `videoRenderer.view` and never sees the pipeline behind it.
    public var videoRenderer: (any KVMVideoRenderer)? { backend?.videoRenderer }
    public var hasReceivedFirstFrame: Bool { backend?.hasReceivedFirstFrame ?? false }
    public var capabilities: KVMCapabilities { backend?.capabilities ?? .none }
    public var latestStats: ConnectionStats? { backend?.latestStats }
    public var statsHistory: [ConnectionStats] { backend?.statsHistory ?? [] }

    // MARK: - JetKVM-only state (neutral defaults elsewhere)

    public var rpcReady: Bool { jetKVM?.rpcReady ?? false }
    public var videoState: VideoState? { jetKVM?.videoState }
    public var usbState: String? { jetKVM?.usbState }
    public var streamQualityFactor: Double? { jetKVM?.streamQualityFactor }
    public var videoCodecPreference: VideoCodecPreference? { jetKVM?.videoCodecPreference }
    public var failsafe: FailsafeModeNotification? { jetKVM?.failsafe }
    public var clipboardAgentState: ClipboardAgentState { jetKVM?.clipboardAgentState ?? .absent }
    public var clipboardBridge: ClipboardBridge? { jetKVM?.clipboardBridge }

    /// VNC's text-only clipboard surface (nil for other backends). The
    /// App-layer `VNCClipboardSyncManager` binds to it.
    public var textClipboard: VNCTextClipboard? { (backend as? VNCBackend)?.textClipboard }

    // MARK: - Power control (backend-agnostic)

    /// Power actions the active backend can perform right now — empty when it
    /// has none, so the App hides the Power section. The App renders one button
    /// per action and switches display copy on the case.
    public var availablePowerActions: [KVMPowerAction] { backend?.availablePowerActions ?? [] }
    /// Front-panel power-LED state, or nil when the backend can't report it.
    public var powerIndicator: Bool? { backend?.powerIndicator }

    /// Perform a power action on the active backend. No-op when the backend
    /// doesn't support it.
    public func sendPowerAction(_ action: KVMPowerAction) async throws {
        try await backend?.sendPowerAction(action)
    }

    /// Down-cast to the JetKVM backend. The read of `backend` keeps
    /// Observation tracking intact for the forwarded properties above.
    private var jetKVM: JetKVMBackend? { backend as? JetKVMBackend }

    // MARK: - Lifecycle

    /// Connect to a device. Selects the backend from `endpoint.kind`,
    /// reusing the existing instance when the kind is unchanged so
    /// reconnect / password-retry flows keep their transport state.
    public func connect(endpoint: DeviceEndpoint, password: String? = nil) async {
        let active = makeBackend(for: endpoint.kind)
        await active.connect(endpoint: endpoint, password: password)
    }

    public func disconnect() async {
        await backend?.disconnect()
    }

    /// Called by KVMVideoView when its renderer reports a non-zero
    /// video size — i.e. frames have actually started rendering.
    public func markFirstFrameReceived() {
        backend?.markFirstFrameReceived()
    }

    private func makeBackend(for kind: DeviceKind) -> any KVMBackend {
        switch kind {
        case .jetKVM:
            let b = (backend as? JetKVMBackend) ?? JetKVMBackend()
            backend = b
            return b
        case .piKVM:
            let b = (backend as? PiKVMBackend) ?? PiKVMBackend()
            backend = b
            return b
        case .vnc:
            let b = (backend as? VNCBackend) ?? VNCBackend()
            backend = b
            return b
        }
    }

    // MARK: - Input (forwarded)

    public func sendKeypress(virtualKeyCode keyCode: UInt16, pressed: Bool) {
        backend?.sendKeypress(virtualKeyCode: keyCode, pressed: pressed)
    }

    public func handleFlagsChanged(virtualKeyCode keyCode: UInt16) {
        backend?.handleFlagsChanged(virtualKeyCode: keyCode)
    }

    public func releaseAllHeldModifiers() {
        backend?.releaseAllHeldModifiers()
    }

    public func sendPointerMotion(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons) {
        backend?.sendPointerMotion(normalizedX: normalizedX, normalizedY: normalizedY, buttons: buttons)
    }

    public func sendPointerButtonChange(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons) {
        backend?.sendPointerButtonChange(normalizedX: normalizedX, normalizedY: normalizedY, buttons: buttons)
    }

    public func sendMouseRelative(dx: Int8, dy: Int8, buttons: MouseButtons) {
        backend?.sendMouseRelative(dx: dx, dy: dy, buttons: buttons)
    }

    public func sendWheelReport(wheelY: Int8, wheelX: Int8) {
        backend?.sendWheelReport(wheelY: wheelY, wheelX: wheelX)
    }

    // MARK: - Bandwidth gate (forwarded)

    public func pauseVideo() { backend?.pauseVideo() }
    public func resumeVideo() { backend?.resumeVideo() }

    // MARK: - JetKVM-only control plane
    //
    // These forward to the JetKVM backend when present. On other
    // backends the corresponding UI is hidden via `capabilities`, so
    // these are no-ops/neutral rather than errors.

    public func updateStreamQualityFactor(_ factor: Double) async {
        await jetKVM?.updateStreamQualityFactor(factor)
    }

    public func updateVideoCodecPreference(_ codec: VideoCodecPreference) async {
        await jetKVM?.updateVideoCodecPreference(codec)
    }
}
