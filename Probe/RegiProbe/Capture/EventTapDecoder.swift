import AppKit
import CoreGraphics
import ProbeKit

/// Turns a `CGEvent` into a `ProbeEvent.Payload`.
///
/// Runs inside the tap callback, so it must stay cheap: field reads and a
/// struct, nothing that allocates beyond the one optional `characters` string.
enum EventTapDecoder {
    static func payload(type: CGEventType, event: CGEvent) -> ProbeEvent.Payload? {
        let sourcePID = Int32(event.getIntegerValueField(.eventSourceUnixProcessID))

        switch type {
        case .keyDown, .keyUp:
            let kvk = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            return .key(.init(
                kvk: kvk,
                down: type == .keyDown,
                autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                // Raw flags, not CGEventFlags: the device-side bits
                // (NX_DEVICELSHIFTKEYMASK etc.) are the only way to prove
                // left/right modifier fidelity.
                rawFlags: event.flags.rawValue,
                characters: characters(of: event),
                sourcePID: sourcePID
            ))

        case .flagsChanged:
            let kvk = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            return .flags(.init(kvk: kvk, rawFlags: event.flags.rawValue))

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .mouseMoved,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let loc = event.location
            return .pointer(.init(
                type: type.rawValue,
                x: Int32(loc.x.rounded()),
                y: Int32(loc.y.rounded()),
                deltaX: Int32(truncatingIfNeeded: event.getIntegerValueField(.mouseEventDeltaX)),
                deltaY: Int32(truncatingIfNeeded: event.getIntegerValueField(.mouseEventDeltaY)),
                buttonNumber: UInt32(truncatingIfNeeded: event.getIntegerValueField(.mouseEventButtonNumber)),
                clickState: UInt32(truncatingIfNeeded: event.getIntegerValueField(.mouseEventClickState)),
                sourcePID: sourcePID
            ))

        case .scrollWheel:
            return .wheel(.init(
                lineDeltaY: Int32(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
                lineDeltaX: Int32(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
                pointDeltaY: Int32(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
                pointDeltaX: Int32(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
                // A KVM wheel detent must arrive discrete; trackpad-style
                // continuous scroll here would be a real finding.
                isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                phase: UInt32(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventScrollPhase)),
                sourcePID: sourcePID
            ))

        default:
            return gesture(type: type, event: event)
        }
    }

    /// Gesture events are NSEvent types outside the documented `CGEventType`
    /// set, so they arrive here as raw values. Regi emits none of these today —
    /// they exist so a pinch can be asserted to produce *nothing*.
    private static func gesture(type: CGEventType, event: CGEvent) -> ProbeEvent.Payload? {
        guard let ns = NSEvent(cgEvent: event) else { return nil }
        switch ns.type {
        case .magnify:      return .gesture(.init(kind: .magnify, value: Double(ns.magnification),
                                                  phase: UInt32(ns.phase.rawValue)))
        case .rotate:       return .gesture(.init(kind: .rotate, value: Double(ns.rotation),
                                                  phase: UInt32(ns.phase.rawValue)))
        case .swipe:        return .gesture(.init(kind: .swipe, value: Double(ns.deltaX),
                                                  secondary: Double(ns.deltaY),
                                                  phase: UInt32(ns.phase.rawValue)))
        case .smartMagnify: return .gesture(.init(kind: .smartMagnify, value: 0))
        case .pressure:     return .gesture(.init(kind: .pressure, value: Double(ns.pressure),
                                                  stage: UInt32(max(0, ns.stage))))
        default:            return nil
        }
    }

    /// `NSEvent.characters`, not `CGEvent.keyboardGetUnicodeString` — the latter
    /// mutates dead-key state, which would corrupt the very input we are
    /// observing.
    private static func characters(of event: CGEvent) -> String {
        NSEvent(cgEvent: event)?.characters ?? ""
    }

    /// Mask covering every event kind the probe records, including the gesture
    /// types that have no `CGEventType` constant.
    static var eventMask: CGEventMask {
        var mask: UInt64 = 0
        for t: CGEventType in [.keyDown, .keyUp, .flagsChanged,
                               .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                               .otherMouseDown, .otherMouseUp, .mouseMoved,
                               .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                               .scrollWheel] {
            mask |= 1 << UInt64(t.rawValue)
        }
        // NSEvent gesture types, which CGEventType does not name.
        for raw: UInt64 in [18 /* rotate */, 19 /* beginGesture */, 20 /* endGesture */,
                            29 /* magnify */, 31 /* swipe */, 32 /* smartMagnify */,
                            34 /* pressure */] {
            mask |= 1 << raw
        }
        return CGEventMask(mask)
    }
}
