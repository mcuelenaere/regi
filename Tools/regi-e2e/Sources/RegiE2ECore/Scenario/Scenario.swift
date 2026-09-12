import CoreGraphics
import Foundation
import ProbeKit

/// A scenario is **data**, not a closure: `replay` has to re-evaluate a
/// recorded run offline, which a closure cannot be serialized into.
public struct Scenario: Equatable {
    public let id: String
    public let title: String
    public let tags: Set<Tag>
    public let steps: [Step]
    /// Runs and records but never affects the exit code. This is how a
    /// known-failing scenario ships on day one as documentation of the gap,
    /// rather than being deleted or turning the suite permanently red.
    public let quarantined: Bool

    public init(id: String, title: String, tags: Set<Tag> = [],
                quarantined: Bool = false, steps: [Step]) {
        self.id = id
        self.title = title
        self.tags = tags
        self.quarantined = quarantined
        self.steps = steps
    }

    public enum Tag: String, Codable, Sendable {
        case keyboard, pointer, modifiers, capture, lifecycle, slow
    }
}

/// Coordinates are framebuffer pixels on the target, never screen points, so a
/// scenario reads the same wherever Regi's window happens to be.
public enum Step: Equatable {
    case key(kvk: UInt16, action: KeyAction)
    /// Modifiers are events, not a property of a keypress. Measured on the rig:
    /// setting `.maskShift` on a key event alone produced "a" on the target,
    /// while a preceding flagsChanged produced "A", because Regi's
    /// ModifierTracker only learns modifier state from flagsChanged.
    case modifier(kvk: UInt16, down: Bool)
    case type(String)
    case moveTo(x: Int, y: Int)
    case click(button: Button, x: Int, y: Int, count: Int)
    case drag(fromX: Int, fromY: Int, toX: Int, toY: Int, steps: Int)
    case focusRegi
    case focusElsewhere
    case wait(millis: Int)
    /// Wait until the probe stops reporting new events. `absent` expectations
    /// are only meaningful after one of these.
    case settle(quietMillis: Int, maxMillis: Int)
    case expect(Expectation)

    public enum KeyAction: Equatable {
        case down, up
        case tap(holdMillis: Int)
    }

    public enum Button: String, Equatable {
        case left, right
    }
}

public enum Expectation: Equatable {
    /// Exactly these key events, in order, with nothing else of that kind
    /// between them.
    case keySequence([KeyMatcher])
    /// These key events in order, tolerating others in between — for cases
    /// where the device legitimately emits extras.
    case keySubsequence([KeyMatcher])
    case keyCount(kvk: UInt16, down: Bool, min: Int, max: Int)
    /// Nothing of this kind arrived. Only meaningful after a completed settle.
    case absent(KindFilter)
    case cursorEndsNear(x: Int, y: Int, tolerance: Int)
    case nothingHeld
    case noUnmatchedReleases
    /// A modifier's last observed transition left it in this state — the
    /// assertion that catches the ⌘Tab inversion class of bug.
    case modifierEndsUp(kvk: UInt16)

    public enum KindFilter: String, Equatable {
        case key, pointer, wheel, gesture, any
    }
}

public struct KeyMatcher: Equatable, CustomStringConvertible {
    public let kvk: UInt16
    public let down: Bool
    /// Optional: assert the character the target produced, which is what proves
    /// modifier state actually reached it (shift+a must yield "A", not "a").
    public let characters: String?

    public init(kvk: UInt16, down: Bool, characters: String? = nil) {
        self.kvk = kvk
        self.down = down
        self.characters = characters
    }

    public static func down(_ kvk: UInt16, _ characters: String? = nil) -> KeyMatcher {
        KeyMatcher(kvk: kvk, down: true, characters: characters)
    }
    public static func up(_ kvk: UInt16, _ characters: String? = nil) -> KeyMatcher {
        KeyMatcher(kvk: kvk, down: false, characters: characters)
    }

    public var description: String {
        var s = "\(KeyLabels.label(kvk))\(down ? "↓" : "↑")"
        if let characters { s += " “\(characters)”" }
        return s
    }

    func matches(_ event: ProbeEvent) -> Bool {
        switch event.payload {
        case .key(let k):
            guard k.kvk == kvk, k.down == down else { return false }
            if let characters, k.characters != characters { return false }
            return true
        case .flags(let f):
            // A modifier arrives as flagsChanged; the flag bit says which way.
            guard f.kvk == kvk, characters == nil else { return false }
            guard let isDown = ModifierFlagBits.isDown(kvk: f.kvk, rawFlags: f.rawFlags)
            else { return false }
            return isDown == down
        default:
            return false
        }
    }
}
