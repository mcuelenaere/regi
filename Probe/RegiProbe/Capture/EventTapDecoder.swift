import CoreGraphics
import ProbeKit

/// Turns a `CGEvent` into a `ProbeEvent.Payload`.
///
/// **No AppKit here, deliberately.** This runs inside the tap callback on a
/// non-main thread, and AppKit is not safe there: `NSEvent.characters` routes
/// through Text Services Manager, which asserts the main queue and traps. That
/// crashed the app on the first keystroke. Character translation now goes
/// through `KeyboardLayoutSnapshot`, which uses `UCKeyTranslate` over a layout
/// blob fetched on the main thread.
///
/// It must also stay cheap: field reads and a struct, nothing more.
enum EventTapDecoder {
    static func payload(type: CGEventType, event: CGEvent,
                        layout: KeyboardLayoutSnapshot) -> ProbeEvent.Payload? {
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
                characters: layout.characters(keyCode: kvk, flags: event.flags),
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

    /// Only the raw event type is available without constructing an `NSEvent`,
    /// which is what is unsafe on this thread. The raw-value mapping lives in
    /// ProbeKit so it can be pinned against AppKit's own constants — see
    /// `GestureKindTests`, which exists because mapping `NSEventTypeGesture`
    /// (29) to magnify (30) made every trackpad cursor movement look like a
    /// pinch.
    ///
    /// Magnitudes stay zero: Regi emits no gestures, so what these are for
    /// today is asserting that a pinch produces *nothing*, and the arrival of
    /// an event of this kind is the whole signal. If magnitudes are ever
    /// needed, retain the CGEvent and decode it on the main thread.
    private static func gesture(type: CGEventType, event: CGEvent) -> ProbeEvent.Payload? {
        guard let kind = ProbeEvent.Gesture.Kind(nsEventTypeRawValue: type.rawValue) else {
            return nil
        }
        return .gesture(.init(kind: kind, value: 0))
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
        // NSEvent gesture types, which CGEventType does not name. The list is
        // shared with the decoder so the mask and the mapping cannot drift --
        // a mismatch either captures events that are then dropped, or drops
        // events that were never captured.
        for raw in ProbeEvent.Gesture.Kind.allNSEventTypeRawValues {
            mask |= 1 << UInt64(raw)
        }
        return CGEventMask(mask)
    }
}
