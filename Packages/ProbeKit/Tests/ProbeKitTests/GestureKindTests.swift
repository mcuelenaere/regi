import AppKit
import XCTest
@testable import ProbeKit

/// Pins the gesture raw values against AppKit. The probe's tap callback cannot
/// import AppKit (`NSEvent.characters` asserts the main queue and traps), so it
/// carries the numbers literally — and a wrong literal mislabels ordinary input
/// rather than failing. A test target has no such constraint.
final class GestureKindTests: XCTestCase {

    func testEachKindMatchesAppKitsConstant() {
        let expected: [(ProbeEvent.Gesture.Kind, NSEvent.EventType)] = [
            (.rotate, .rotate),
            (.magnify, .magnify),
            (.swipe, .swipe),
            (.smartMagnify, .smartMagnify),
            (.pressure, .pressure),
        ]
        for (kind, nsType) in expected {
            XCTAssertEqual(kind.nsEventTypeRawValue, UInt32(nsType.rawValue),
                           "\(kind) is mapped to the wrong NSEvent type")
            XCTAssertEqual(ProbeEvent.Gesture.Kind(nsEventTypeRawValue: UInt32(nsType.rawValue)),
                           kind)
        }
    }

    /// The regression that prompted this. `NSEventTypeGesture` is 29 and
    /// `NSEventTypeMagnify` is 30; mapping 29 to magnify meant every trackpad
    /// cursor movement was recorded as a pinch.
    func testGenericGestureLifecycleEventsAreNotMistakenForGestures() {
        for nsType: NSEvent.EventType in [.gesture, .beginGesture, .endGesture] {
            XCTAssertNil(ProbeEvent.Gesture.Kind(nsEventTypeRawValue: UInt32(nsType.rawValue)),
                         "\(nsType.rawValue) carries no gesture identity and fires "
                         + "constantly during trackpad use — it must not map to a kind")
        }
        XCTAssertNotEqual(NSEvent.EventType.gesture.rawValue, NSEvent.EventType.magnify.rawValue)
    }

    /// Ordinary input must never be read as a gesture.
    func testOrdinaryEventTypesDoNotMapToGestures() {
        for nsType: NSEvent.EventType in [.mouseMoved, .scrollWheel, .keyDown, .keyUp,
                                          .flagsChanged, .leftMouseDown, .leftMouseDragged,
                                          .otherMouseDown, .directTouch, .quickLook] {
            XCTAssertNil(ProbeEvent.Gesture.Kind(nsEventTypeRawValue: UInt32(nsType.rawValue)),
                         "NSEvent type \(nsType.rawValue) must not map to a gesture kind")
        }
    }

    func testMaskListMatchesTheMappableKinds() {
        let listed = Set(ProbeEvent.Gesture.Kind.allNSEventTypeRawValues)
        let mappable = Set([ProbeEvent.Gesture.Kind.rotate, .magnify, .swipe, .smartMagnify, .pressure]
            .map(\.nsEventTypeRawValue))
        XCTAssertEqual(listed, mappable,
                       "the tap mask and the decoder must agree, or events are either "
                       + "captured and dropped, or never captured at all")
    }
}
