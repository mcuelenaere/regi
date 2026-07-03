import XCTest
@testable import KVMCore

final class ModifierTrackerTests: XCTestCase {

    func testStartsEmpty() {
        let tracker = ModifierTracker()
        XCTAssertTrue(tracker.currentState.isEmpty)
    }

    func testPressShiftEmitsLeftShiftPressed() {
        var tracker = ModifierTracker()
        let transition = tracker.handle(modifierKeyCode: 0x38) // kVK_Shift
        XCTAssertEqual(transition, ModifierTransition(modifier: .leftShift, pressed: true))
        XCTAssertEqual(tracker.currentState, .leftShift)
    }

    func testReleaseAfterPressEmitsReleased() {
        var tracker = ModifierTracker()
        _ = tracker.handle(modifierKeyCode: 0x38) // press shift
        let release = tracker.handle(modifierKeyCode: 0x38) // release shift
        XCTAssertEqual(release, ModifierTransition(modifier: .leftShift, pressed: false))
        XCTAssertTrue(tracker.currentState.isEmpty)
    }

    /// The plan's canonical fixture: hold Shift, then Cmd, then release
    /// Shift — three discrete events.
    func testHoldShiftThenCmdThenReleaseShift() {
        var tracker = ModifierTracker()
        let e1 = tracker.handle(modifierKeyCode: 0x38) // press shift
        let e2 = tracker.handle(modifierKeyCode: 0x37) // press cmd
        let e3 = tracker.handle(modifierKeyCode: 0x38) // release shift

        XCTAssertEqual(e1, ModifierTransition(modifier: .leftShift, pressed: true))
        XCTAssertEqual(e2, ModifierTransition(modifier: .leftMeta, pressed: true))
        XCTAssertEqual(e3, ModifierTransition(modifier: .leftShift, pressed: false))
        XCTAssertEqual(tracker.currentState, .leftMeta)
    }

    func testRightSideModifiers() {
        var tracker = ModifierTracker()
        XCTAssertEqual(
            tracker.handle(modifierKeyCode: 0x3C),
            ModifierTransition(modifier: .rightShift, pressed: true)
        )
        XCTAssertEqual(
            tracker.handle(modifierKeyCode: 0x3E),
            ModifierTransition(modifier: .rightControl, pressed: true)
        )
        XCTAssertEqual(tracker.currentState, [.rightShift, .rightControl])
    }

    func testNonModifierKeyCodeReturnsNil() {
        var tracker = ModifierTracker()
        XCTAssertNil(tracker.handle(modifierKeyCode: 0x00)) // KeyA
        XCTAssertNil(tracker.handle(modifierKeyCode: 0x39)) // CapsLock — intentionally not tracked
        XCTAssertNil(tracker.handle(modifierKeyCode: 0x3F)) // kVK_Function — also skipped
    }

    func testResetClearsState() {
        var tracker = ModifierTracker()
        _ = tracker.handle(modifierKeyCode: 0x37) // cmd
        _ = tracker.handle(modifierKeyCode: 0x38) // shift
        XCTAssertFalse(tracker.currentState.isEmpty)
        tracker.reset()
        XCTAssertTrue(tracker.currentState.isEmpty)
    }

    func testCurrentStateAsModifierByteForCmdShiftA() {
        // Cmd+Shift held: byte should be 0x0A (LeftMeta + LeftShift).
        var tracker = ModifierTracker()
        _ = tracker.handle(modifierKeyCode: 0x37) // cmd
        _ = tracker.handle(modifierKeyCode: 0x38) // shift
        XCTAssertEqual(tracker.currentState.rawValue, 0x0A)
    }
}
