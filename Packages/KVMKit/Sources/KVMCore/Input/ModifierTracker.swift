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
/// toggled, so the keyCode (0x36..0x3E) names the key and the event's
/// raw flags say whether it ended up down.
///
/// **The flags are authoritative; do not infer state by toggling.** This
/// tracker used to toggle on each keyCode and ignore the flags, which
/// broke whenever a transition happened outside our window — the classic
/// case being ⌘Tab, where we see ⌘ go down and never see it released.
/// The old doc claimed "the next press of that modifier will re-sync the
/// tracker", but the opposite happened: the next press toggled the stale
/// `true` to `false`, so pressing ⌘ sent a *release* and releasing it
/// sent a *press*. Every ⌘ was inverted from then on, and only a
/// reconnect cleared it.
///
/// Reading the flag bit makes state self-correcting: whatever was missed,
/// the very next event restores agreement with the real keyboard.
/// `reset()` remains available for disconnect/reconnect.
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

    /// Process a `flagsChanged` event. `rawFlags` is
    /// `NSEvent.modifierFlags.rawValue` or `CGEvent.flags.rawValue` — both
    /// carry the device-side bits, verified on macOS 26.
    ///
    /// Returns the resulting transition if the keyCode names one of the eight
    /// modifier keys, or `nil` otherwise (caps lock and `fn`, which we don't
    /// translate). Returns `nil` too when the flags already agree with our
    /// state, so a redundant event does not produce a spurious press or
    /// release.
    public mutating func handle(modifierKeyCode keyCode: UInt16,
                                rawFlags: UInt64) -> ModifierTransition? {
        guard let modifier = Self.modifier(forKeyCode: keyCode),
              let deviceBit = Self.deviceFlagBit(forKeyCode: keyCode) else { return nil }

        let isDown = rawFlags & deviceBit != 0
        let wasDown = current.contains(modifier)
        guard isDown != wasDown else { return nil }

        if isDown { current.insert(modifier) } else { current.remove(modifier) }
        return ModifierTransition(modifier: modifier, pressed: isDown)
    }

    /// kVK_* values from <Carbon/HIToolbox/Events.h>.
    public static func modifier(forKeyCode keyCode: UInt16) -> ModifierBits? {
        switch keyCode {
        case 0x37: return .leftMeta     // kVK_Command
        case 0x38: return .leftShift    // kVK_Shift
        case 0x3A: return .leftAlt      // kVK_Option
        case 0x3B: return .leftControl  // kVK_Control
        case 0x36: return .rightMeta    // kVK_RightCommand
        case 0x3C: return .rightShift   // kVK_RightShift
        case 0x3D: return .rightAlt     // kVK_RightOption
        case 0x3E: return .rightControl // kVK_RightControl
        default: return nil
        }
    }

    /// Device-dependent bits from `IOLLEvent.h` (`NX_DEVICE*KEYMASK`). These
    /// are the only way to tell left from right: the documented coarse masks
    /// (`.maskCommand`, `NSEvent.ModifierFlags.command`) collapse both sides
    /// into one bit, so releasing one of two held ⌘ keys would look like
    /// neither being released.
    public static func deviceFlagBit(forKeyCode keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case 0x3B: return 0x0000_0001   // left control
        case 0x38: return 0x0000_0002   // left shift
        case 0x3C: return 0x0000_0004   // right shift
        case 0x37: return 0x0000_0008   // left command
        case 0x36: return 0x0000_0010   // right command
        case 0x3A: return 0x0000_0020   // left option
        case 0x3D: return 0x0000_0040   // right option
        case 0x3E: return 0x0000_2000   // right control
        default: return nil
        }
    }
}
