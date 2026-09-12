import Foundation

/// Gesture events are `NSEvent` types with no `CGEventType` constants, so a tap
/// sees them only as raw numbers.
///
/// These are magic numbers in the worst way: a wrong one does not fail, it
/// silently relabels ordinary input as a gesture. That happened —
/// `NSEventTypeGesture` (29) was mistaken for `NSEventTypeMagnify` (30), and
/// since macOS posts the generic gesture event continuously during trackpad
/// use, every cursor movement was recorded as a magnify.
///
/// `GestureKindTests` pins each value against AppKit's own constants, which is
/// the check that would have caught it.
extension ProbeEvent.Gesture.Kind {
    public init?(nsEventTypeRawValue raw: UInt32) {
        switch raw {
        case 18: self = .rotate
        case 30: self = .magnify
        case 31: self = .swipe
        case 32: self = .smartMagnify
        case 34: self = .pressure
        default: return nil
        }
    }

    public var nsEventTypeRawValue: UInt32 {
        switch self {
        case .rotate:       return 18
        case .magnify:      return 30
        case .swipe:        return 31
        case .smartMagnify: return 32
        case .pressure:     return 34
        }
    }

    /// Exactly the specific gestures, deliberately excluding the generic
    /// lifecycle events `gesture` (29), `beginGesture` (19) and `endGesture`
    /// (20): they carry no gesture identity and fire throughout ordinary
    /// trackpad use, so recording them would break "nothing extra arrived"
    /// assertions with noise.
    public static var allNSEventTypeRawValues: [UInt32] {
        [18, 30, 31, 32, 34]
    }
}
