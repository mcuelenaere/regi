import AppKit
import CoreVideo
import Foundation
import JetKVMProtocol

/// One locally-decoded frame ready to present, from a backend that renders
/// its own video (VNC) rather than receiving a WebRTC track. Reference type
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

/// Producer side of the locally-decoded video path (VNC): the backend's decode
/// task invokes `onFrame` once per frame. `LocalVideoRenderer` consumes it. Not
/// `@MainActor`: the closure is `@Sendable` and the implementation must
/// synchronize its own storage, since it's set on the main actor but called
/// from the decode path.
public protocol LocalVideoOutput: AnyObject, Sendable {
    var onFrame: (@Sendable (LocalVideoFrame) -> Void)? { get set }
}

/// A backend-owned video renderer. Each backend builds the renderer that suits
/// its video technology — `WebRTCVideoRenderer` (JetKVM/PiKVM) or
/// `LocalVideoRenderer` (VNC) — and the App embeds `view` and observes size
/// changes. This keeps WebRTC out of `KVMCore` and the App: the host view never
/// has to know which pipeline is behind the pixels.
///
/// `@MainActor` because it vends and mutates an `NSView`.
@MainActor
public protocol KVMVideoRenderer: AnyObject {
    /// The view that displays the video. The host embeds it and owns layout.
    var view: NSView { get }
    /// Fired on the main actor when the source video size changes. The first
    /// non-zero size doubles as "first frame rendered"; the host also uses the
    /// size for aspect-fit coordinate mapping.
    var onVideoSizeChanged: ((CGSize) -> Void)? { get set }
    /// Stop rendering and release the hookup to the video source.
    func detach()
}

/// Which family of KVM device a connection targets. Carried on
/// `DeviceEndpoint` and used by `Session` to pick the right backend.
/// JetKVM and PiKVM speak entirely different protocols (see the PiKVM
/// support plan) but share the same App-layer UI through the `Session`
/// façade.
public enum DeviceKind: String, Sendable, Codable, Hashable, CaseIterable {
    case jetKVM
    case piKVM
    /// A plain RFB server reachable over TCP (QEMU/libvirt `-vnc`, Proxmox
    /// VM consoles reached via their QEMU VNC port, etc.).
    case vnc

    /// Human-facing label for the device family (used in the host list
    /// and the add-host form).
    public var displayName: String {
        switch self {
        case .jetKVM: return "JetKVM"
        case .piKVM: return "PiKVM"
        case .vnc: return "VNC"
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
    /// Password (and, for PiKVM, username) required. The UI collects the
    /// credential and re-runs `connect(...)`.
    case awaitingPassword
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

/// A power-control action a backend can perform. Semantic, not wire-level:
/// each backend maps the cases it supports to its own protocol (JetKVM ATX RPC,
/// VNC XVP). The App renders a button per `KVMBackend.availablePowerActions`
/// and switches display copy on the case, so the panel needs no per-backend
/// branching.
public enum KVMPowerAction: String, Sendable, CaseIterable {
    /// Momentary power-button press — clean power-on / ACPI power-off.
    case powerButtonShort
    /// Held power-button press — force power-off.
    case powerButtonLong
    /// Hard reset (physical reset line / XVP reset).
    case reset
    /// ACPI shutdown request to the guest OS.
    case shutdown
    /// Reboot request (XVP; modelled for servers that honour it).
    case reboot
}

/// Which optional control-plane features a connected backend exposes.
/// The App layer gates JetKVM-only UI (codec/quality, the clipboard agent) on
/// these so a PiKVM session shows only what it can actually drive. JetKVM
/// advertises everything; PiKVM v1 advertises nothing (core video + input
/// only). Power control is gated separately on `availablePowerActions`.
public struct KVMCapabilities: Sendable, Equatable {
    public var videoCodecPreference: Bool
    public var streamQuality: Bool
    public var clipboardSync: Bool
    public var pauseResume: Bool

    public init(
        videoCodecPreference: Bool = false,
        streamQuality: Bool = false,
        clipboardSync: Bool = false,
        pauseResume: Bool = false
    ) {
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
    /// The renderer for the live video, or nil before video is available.
    /// The backend builds the renderer matching its video technology; the
    /// App embeds `videoRenderer.view`.
    var videoRenderer: (any KVMVideoRenderer)? { get }
    var hasReceivedFirstFrame: Bool { get }
    var capabilities: KVMCapabilities { get }
    var latestStats: ConnectionStats? { get }
    var statsHistory: [ConnectionStats] { get }

    // Power control. Empty when the backend can't drive power (PiKVM, VNC
    // without XVP) — the App hides the Power section then. `powerIndicator`
    // is the front-panel power-LED state, or nil when the backend can't
    // report it (VNC).
    var availablePowerActions: [KVMPowerAction] { get }
    var powerIndicator: Bool? { get }
    func sendPowerAction(_ action: KVMPowerAction) async throws

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
    /// Backends without power control (PiKVM) inherit these no-op defaults.
    var availablePowerActions: [KVMPowerAction] { [] }
    var powerIndicator: Bool? { nil }
    func sendPowerAction(_ action: KVMPowerAction) async throws {}
}
