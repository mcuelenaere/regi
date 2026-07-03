import Foundation
import Observation

/// The App-facing surface for VNC clipboard sync — text only. One per
/// `VNCBackend`. The App-layer `VNCClipboardSyncManager` binds `onRemoteText`
/// (to apply incoming text to `NSPasteboard`) and calls `onLocalText` (when the
/// local pasteboard changes); the backend owns the RFB clipboard state machine
/// behind it.
///
/// `@Observable` so SwiftUI (the clipboard toggle in `ControlPanel`) tracks
/// `isAvailable`/`supportsUTF8`.
@MainActor
@Observable
public final class VNCTextClipboard {
    /// True while connected — the sync manager gates on this.
    public internal(set) var isAvailable = false
    /// True once the server negotiated the Extended Clipboard (UTF-8). When
    /// false, only Latin-1 classic cut text is exchanged.
    public internal(set) var supportsUTF8 = false

    /// Set by the sync manager; the backend calls it (on the main actor) when
    /// remote clipboard text arrives.
    @ObservationIgnored public var onRemoteText: ((String) -> Void)?
    /// Set by the backend; invoked by `setLocalText` when the local pasteboard
    /// text changes (nil to clear).
    @ObservationIgnored var onLocalText: ((String?) -> Void)?

    public init() {}

    /// Called by the App-layer sync manager when the local pasteboard text
    /// changes; forwards to the backend's clipboard state machine.
    public func setLocalText(_ text: String?) {
        onLocalText?(text)
    }
}
