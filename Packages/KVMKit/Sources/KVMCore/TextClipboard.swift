// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// The App-facing surface for a text-only clipboard: VNC cut text, or a
/// JetKVM's OS Services clipboard. The App-layer `TextClipboardSyncManager`
/// binds `onRemoteText` (to apply incoming text to `NSPasteboard`) and calls
/// `setLocalText` (when the local pasteboard changes); the backend owns the
/// protocol behind it.
///
/// `@Observable` so SwiftUI (the clipboard toggle in `ControlPanel`) tracks
/// `isAvailable`/`supportsUTF8`.
@MainActor
@Observable
public final class TextClipboard {
    /// True while the remote clipboard can be used — the sync manager gates
    /// on this.
    public var isAvailable = false
    /// False while only Latin-1 text can be exchanged (VNC without the
    /// Extended Clipboard).
    public var supportsUTF8 = false

    /// Set by the sync manager; the backend calls it (on the main actor) when
    /// remote clipboard text arrives.
    @ObservationIgnored public var onRemoteText: ((String) -> Void)?
    /// Set by the backend; invoked by `setLocalText` when the local pasteboard
    /// text changes (nil to clear).
    @ObservationIgnored public var onLocalText: ((String?) -> Void)?
    /// Set by a backend whose remote side never pushes (OS Services): invoked
    /// by `fetchRemoteText` to read the remote clipboard now. Nil when the
    /// remote pushes its changes on its own (VNC).
    @ObservationIgnored public var onFetchRemote: (() -> Void)?

    public init() {}

    /// Called by the App-layer sync manager when the local pasteboard text
    /// changes; forwards to the backend's clipboard state machine.
    public func setLocalText(_ text: String?) {
        onLocalText?(text)
    }

    /// Called by the sync manager when the operator is likely about to paste
    /// locally (Regi lost focus). A changed remote text arrives through
    /// `onRemoteText`.
    public func fetchRemoteText() {
        onFetchRemote?()
    }
}
