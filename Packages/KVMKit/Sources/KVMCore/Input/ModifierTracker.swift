import Foundation

/// One discrete modifier-key transition: which bit changed and whether
/// it ended up pressed.
public struct ModifierTransition: Sendable, Equatable {
    public let modifier: ModifierBits
    public let pressed: Bool

    public init(modifier: ModifierBits, pressed: Bool) {
        self.modifier = modifier
        self.pressed = pressed
    }
}

/// Translates `NSEvent.flagsChanged` callbacks into discrete
/// press/release events.
///
/// `flagsChanged` reports the *combined* modifier state, not which key
/// toggled — so we maintain our own state of which side of each
/// modifier is pressed and toggle it whenever the matching keyCode
/// (0x36..0x3E for the eight modifier keys) fires.
///
/// Out-of-window state desync (e.g. user held Shift, switched apps,
/// released Shift outside our window) is recoverable: the next press
/// of that modifier will re-sync the tracker. Callers can also call
/// `reset()` when the window regains focus to defensively clear all
/// modifier state.
public struct ModifierTracker: Sendable {
    private var current: ModifierBits = []

    public init() {}

    /// Read-only view of the currently-held modifiers from this
    /// tracker's perspective.
    public var currentState: ModifierBits {
        current
    }

    /// Reset to "no modifiers held". Call when the window regains
    /// focus or after a known-disconnected state.
    public mutating func reset() {
        current = []
    }

    /// Process a `keyCode` value from `NSEvent.flagsChanged`. Returns
    /// the resulting transition if the keyCode names one of the eight
    /// modifier keys; returns `nil` otherwise (e.g. `caps lock` or
    /// `function` keys, which we don't translate).
    public mutating func handle(modifierKeyCode keyCode: UInt16) -> ModifierTransition? {
        let modifier: ModifierBits
        switch keyCode {
        // kVK_* values from <Carbon/HIToolbox/Events.h>
        case 0x37: modifier = .leftMeta     // kVK_Command
        case 0x38: modifier = .leftShift    // kVK_Shift
        case 0x3A: modifier = .leftAlt      // kVK_Option
        case 0x3B: modifier = .leftControl  // kVK_Control
        case 0x36: modifier = .rightMeta    // kVK_RightCommand
        case 0x3C: modifier = .rightShift   // kVK_RightShift
        case 0x3D: modifier = .rightAlt     // kVK_RightOption
        case 0x3E: modifier = .rightControl // kVK_RightControl
        default: return nil
        }
        if current.contains(modifier) {
            current.remove(modifier)
            return ModifierTransition(modifier: modifier, pressed: false)
        } else {
            current.insert(modifier)
            return ModifierTransition(modifier: modifier, pressed: true)
        }
    }
}
