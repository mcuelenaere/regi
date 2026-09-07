import Foundation

/// Which of the App's two keyboard paths a key event arrived by. They
/// differ in exactly one way that backends care about: whether a
/// matching release can be trusted to arrive.
///
/// AppKit routes `Cmd+<letter>` combos that match a menu shortcut
/// through `performKeyEquivalent` and never delivers the `keyUp`. A
/// backend that tracked such a press as a hold would strand it on the
/// host, so it has to synthesize the release instead. A `CGEventTap`
/// sits upstream of that routing and sees every press and release, so
/// it needs no workaround — and applying one anyway is actively worse:
/// the host never sees the key held, so its own key-repeat never
/// engages and Cmd-shortcuts behave unlike every other key.
///
/// The two paths are mutually exclusive at any instant. While the tap
/// is installed it swallows the events it forwards, so AppKit never
/// sees them; while it isn't, only the AppKit path fires. That's why
/// this travels with each event rather than living as backend state —
/// there's no window in which an in-flight event could be attributed
/// to the wrong path.
public enum KeyEventSource: Sendable, Equatable {
    /// `NSView.keyDown` / `keyUp` / `flagsChanged`.
    case appKit
    /// Our session-level `CGEventTap` — i.e. keyboard capture is on.
    case eventTap

    /// True when a `Cmd`-modified press has no reliable `keyUp`
    /// coming, so a backend must emit press+release atomically rather
    /// than track a hold it can never clear.
    public var needsSynthesizedCmdRelease: Bool {
        self == .appKit
    }
}
