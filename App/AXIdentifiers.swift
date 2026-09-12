import Foundation

/// Accessibility identifiers for the controls the E2E harness drives.
///
/// These are inert metadata that also improve real accessibility, so they ship
/// in Release and need no build-configuration gating. They exist so `regi-e2e`
/// can drive the app the way a user does — pressing the real controls — rather
/// than through a test-only back door.
///
/// `Tools/regi-e2e` carries a matching list. There is no compile-time link
/// between the two (the CLI does not depend on the app), so `regi-e2e doctor`
/// resolves every identifier as an explicit check: a UI refactor that drops one
/// then reports "identifier not found" instead of a scenario failing for
/// mysterious reasons.
enum AXIdentifiers {
    /// The video surface. Its `AXFrame` is the coordinate basis for every
    /// synthesised pointer event, which is why this one matters most.
    static let sessionVideoView = "session.videoView"

    /// Host video resolution, e.g. "1920×1080". The driver needs the source
    /// size to compute the aspect-fit letterbox rect itself — deriving it
    /// rather than asking Regi means a bug in Regi's own letterbox math makes
    /// a test fail instead of hiding.
    static let sessionResolutionText = "session.resolutionText"

    /// Toolbar menu holding the capture toggles. The toggles only enter the
    /// accessibility tree while it is open.
    static let sessionCaptureMenu = "session.captureMenu"
    static let sessionKeyboardCaptureToggle = "session.keyboardCaptureToggle"
    static let sessionPointerLockToggle = "session.pointerLockToggle"
    static let sessionHideCursorToggle = "session.hideCursorToggle"

    static let sessionControlsButton = "session.controlsButton"
    static let sessionStatsButton = "session.statsButton"

    static let hostsAddButton = "hosts.addButton"
    /// Per-host row: `hosts.row.<host>`. Connecting is opening one.
    static func hostsRow(_ host: String) -> String { "hosts.row.\(host)" }

    /// The pointer-lock confirmation alert. Exposed so a scenario can dismiss
    /// the real alert rather than requiring it be suppressed.
    static let pointerLockConfirmButton = "alert.pointerLock.confirm"
}
