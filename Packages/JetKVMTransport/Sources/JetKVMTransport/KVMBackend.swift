import Foundation
import JetKVMProtocol
import CoreVideo
import WebRTC

/// One locally-decoded frame ready to present, from a backend that renders
/// its own video (SPICE) rather than receiving a WebRTC track. Reference type
/// and `@unchecked Sendable` because `CVPixelBuffer` isn't `Sendable`, but the
/// producer hands off exclusive ownership across the decode-thread → main-actor
/// boundary and never mutates it afterward.
public final class LocalVideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let width: Int
    public let height: Int
    public init(pixelBuffer: CVPixelBuffer, width: Int, height: Int) {
        self.pixelBuffer = pixelBuffer
        self.width = width
        self.height = height
    }
}

/// Video output for backends that decode frames locally (SPICE) and present
/// them directly, with no WebRTC pipeline in between. Mutually exclusive with
/// `KVMBackend.videoTrack`. The view sets `onFrame`; the backend invokes it
/// (possibly off the main actor) once per decoded frame. Not `@MainActor`: the
/// closure is `@Sendable` and the implementation must synchronize its own
/// storage, since it's set on the main actor but called from the decode path.
public protocol LocalVideoOutput: AnyObject, Sendable {
    var onFrame: (@Sendable (LocalVideoFrame) -> Void)? { get set }
}

/// Which family of KVM device a connection targets. Carried on
/// `DeviceEndpoint` and used by `Session` to pick the right backend.
/// JetKVM and PiKVM speak entirely different protocols (see the PiKVM
/// support plan) but share the same App-layer UI through the `Session`
/// façade.
public enum DeviceKind: String, Sendable, Codable, Hashable, CaseIterable {
    case jetKVM
    case piKVM
    case spice

    /// Human-facing label for the device family (used in the host list
    /// and the add-host form).
    public var displayName: String {
        switch self {
        case .jetKVM: return "JetKVM"
        case .piKVM: return "PiKVM"
        case .spice: return "SPICE"
        }
    }
}

/// Connection state surfaced to the UI. Shared across backends so the
/// App layer's `ConnectionStatusView` / `KVMWindowView` switches work
/// regardless of device kind. (Was `Session.State`; `Session.State`
/// remains a typealias to this.)
public enum KVMState: Equatable, Sendable {
    case idle
    case connecting(Phase)
    /// Password (and, for PiKVM, username) required. The associated
    /// `LocalDevice?` is JetKVM's device record for re-display; PiKVM
    /// passes `nil`.
    case awaitingPassword(LocalDevice?)
    /// First request to the device failed system trust evaluation and
    /// the user hasn't opted into trusting self-signed certs for this
    /// host. UI prompts; on accept the caller re-runs `connect(...)`
    /// with `endpoint.allowSelfSignedCertificate == true`.
    case awaitingTrustOverride(host: String, reason: String)
    case connected
    /// Connection dropped after we'd been `.connected`; backing off
    /// before the next retry. `attempt` counts up across the reconnect
    /// cycle (1 = first retry).
    case reconnecting(attempt: Int)
    case kicked
    case failed(String)

    public enum Phase: Sendable {
        case checkingStatus
        case authenticating
        case signaling
        case offering
        case awaitingAnswer
        case iceGathering
    }
}

/// Which optional control-plane features a connected backend exposes.
/// The App layer gates JetKVM-only UI (ATX power, codec/quality, the
/// clipboard agent) on these so a PiKVM session shows only what it can
/// actually drive. JetKVM advertises everything; PiKVM v1 advertises
/// nothing (core video + input only).
public struct KVMCapabilities: Sendable, Equatable {
    public var atxPower: Bool
    public var videoCodecPreference: Bool
    public var streamQuality: Bool
    public var clipboardSync: Bool
    public var pauseResume: Bool

    public init(
        atxPower: Bool = false,
        videoCodecPreference: Bool = false,
        streamQuality: Bool = false,
        clipboardSync: Bool = false,
        pauseResume: Bool = false
    ) {
        self.atxPower = atxPower
        self.videoCodecPreference = videoCodecPreference
        self.streamQuality = streamQuality
        self.clipboardSync = clipboardSync
        self.pauseResume = pauseResume
    }

    /// No optional features — the baseline a bare video+input backend
    /// (PiKVM v1) advertises.
    public static let none = KVMCapabilities()

    /// Everything the JetKVM transport supports today.
    public static let jetKVM = KVMCapabilities(
        atxPower: true,
        videoCodecPreference: true,
        streamQuality: true,
        clipboardSync: true,
        pauseResume: true
    )
}

/// The behaviour `Session` delegates to per device kind. Implemented by
/// `JetKVMBackend` (WebRTC + HID-RPC + JSON-RPC) and `PiKVMBackend`
/// (Janus WebRTC video + `/api/ws` JSON input). The backend owns the
/// live transport and publishes observable state; `Session` is a thin
/// `@Observable` façade that forwards reads and input to whichever
/// backend is active.
///
/// `@MainActor` so SwiftUI can observe the backends' `@Observable`
/// state directly through the façade without a translation layer.
@MainActor
public protocol KVMBackend: AnyObject {
    // Observable connection state
    var state: KVMState { get }
    var videoTrack: RTCVideoTrack? { get }
    /// Locally-decoded video output (SPICE). Nil for WebRTC backends, which
    /// expose `videoTrack` instead. The two are mutually exclusive.
    var localVideoOutput: LocalVideoOutput? { get }
    var hasReceivedFirstFrame: Bool { get }
    var capabilities: KVMCapabilities { get }
    var latestStats: ConnectionStats? { get }
    var statsHistory: [ConnectionStats] { get }

    // Lifecycle
    func connect(endpoint: DeviceEndpoint, password: String?) async
    func disconnect() async
    func markFirstFrameReceived()

    // Input — the App layer's normalized contract (virtual keycodes,
    // 0..32767 absolute coords, signed-byte relative deltas). Each
    // backend translates to its own wire format.
    func sendKeypress(virtualKeyCode: UInt16, pressed: Bool)
    func handleFlagsChanged(virtualKeyCode: UInt16)
    func releaseAllHeldModifiers()
    func sendPointerMotion(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons)
    func sendPointerButtonChange(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons)
    func sendMouseRelative(dx: Int8, dy: Int8, buttons: MouseButtons)
    func sendWheelReport(wheelY: Int8, wheelX: Int8)

    // Bandwidth gate. JetKVM pauses the encoder feed; PiKVM v1 no-ops.
    func pauseVideo()
    func resumeVideo()
}

public extension KVMBackend {
    /// WebRTC backends (JetKVM, PiKVM) render via `videoTrack`, not a local
    /// output. Only SPICE overrides this.
    var localVideoOutput: LocalVideoOutput? { nil }
}
