import Foundation

/// What to show in an event log.
///
/// Motion dominates every capture — a few seconds of hand movement buries the
/// handful of transitions that actually matter — so verifying a click bug by
/// eye means filtering first. Shared rather than local to the probe's UI so
/// the driver's `watch` can offer the same vocabulary.
public enum EventKindFilter: String, CaseIterable, Sendable {
    case all
    /// Button presses and releases only: no motion, no drags. This is the one
    /// that makes a double-click bug visible by eye.
    case buttons
    /// Anything the pointer did, transitions and motion alike.
    case pointer
    case keys
    case wheel
    case gestures
    /// Violations and lifecycle markers the probe inserted itself.
    case diagnostics

    public var label: String {
        switch self {
        case .all:         return "All"
        case .buttons:     return "Clicks"
        case .pointer:     return "Pointer"
        case .keys:        return "Keys"
        case .wheel:       return "Wheel"
        case .gestures:    return "Gestures"
        case .diagnostics: return "Diagnostics"
        }
    }

    public func matches(_ event: ProbeEvent) -> Bool {
        switch (self, event.payload) {
        case (.all, _):
            return true
        case (.buttons, .pointer(let p)):
            return PointerButton.transition(type: p.type, buttonNumber: p.buttonNumber) != nil
        case (.pointer, .pointer):
            return true
        case (.keys, .key), (.keys, .flags):
            return true
        case (.wheel, .wheel):
            return true
        case (.gestures, .gesture), (.gestures, .touches):
            return true
        case (.diagnostics, .diagnostic):
            return true
        default:
            return false
        }
    }
}
