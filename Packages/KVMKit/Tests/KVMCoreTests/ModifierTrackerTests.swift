import XCTest
@testable import KVMCore

final class ModifierTrackerTests: XCTestCase {

    // Device-dependent bits from IOLLEvent.h, plus the coarse masks macOS sets
    // alongside them. Building fixtures the way a real event looks keeps these
    // tests honest about what the tracker actually receives.
    private enum Flag {
        static let lShift: UInt64 = 0x0002, rShift: UInt64 = 0x0004
        static let lCtrl: UInt64 = 0x0001,  rCtrl: UInt64 = 0x2000
        static let lAlt: UInt64 = 0x0020,   rAlt: UInt64 = 0x0040
        static let lCmd: UInt64 = 0x0008,   rCmd: UInt64 = 0x0010
        static let shiftMask: UInt64 = 0x0002_0000
        static let ctrlMask: UInt64 = 0x0004_0000
        static let altMask: UInt64 = 0x0008_0000
        static let cmdMask: UInt64 = 0x0010_0000
    }

    func testStartsEmpty() {
        XCTAssertTrue(ModifierTracker().currentState.isEmpty)
    }

    func testPressShiftEmitsLeftShiftPressed() {
        var tracker = ModifierTracker()
        let t = tracker.handle(modifierKeyCode: 0x38, rawFlags: Flag.shiftMask | Flag.lShift)
        XCTAssertEqual(t, ModifierTransition(modifier: .leftShift, pressed: true))
        XCTAssertEqual(tracker.currentState, .leftShift)
    }

    func testReleaseAfterPressEmitsReleased() {
        var tracker = ModifierTracker()
        _ = tracker.handle(modifierKeyCode: 0x38, rawFlags: Flag.shiftMask | Flag.lShift)
        let release = tracker.handle(modifierKeyCode: 0x38, rawFlags: 0)
        XCTAssertEqual(release, ModifierTransition(modifier: .leftShift, pressed: false))
        XCTAssertTrue(tracker.currentState.isEmpty)
    }

    func testHoldShiftThenCmdThenReleaseShift() {
        var tracker = ModifierTracker()
        let e1 = tracker.handle(modifierKeyCode: 0x38, rawFlags: Flag.shiftMask | Flag.lShift)
        let e2 = tracker.handle(modifierKeyCode: 0x37,
                                rawFlags: Flag.shiftMask | Flag.lShift | Flag.cmdMask | Flag.lCmd)
        let e3 = tracker.handle(modifierKeyCode: 0x38, rawFlags: Flag.cmdMask | Flag.lCmd)

        XCTAssertEqual(e1, ModifierTransition(modifier: .leftShift, pressed: true))
        XCTAssertEqual(e2, ModifierTransition(modifier: .leftMeta, pressed: true))
        XCTAssertEqual(e3, ModifierTransition(modifier: .leftShift, pressed: false))
        XCTAssertEqual(tracker.currentState, .leftMeta)
    }

    func testRightSideModifiersAreDistinctFromLeft() {
        var tracker = ModifierTracker()
        let l = tracker.handle(modifierKeyCode: 0x38, rawFlags: Flag.shiftMask | Flag.lShift)
        let r = tracker.handle(modifierKeyCode: 0x3C,
                               rawFlags: Flag.shiftMask | Flag.lShift | Flag.rShift)
        XCTAssertEqual(l, ModifierTransition(modifier: .leftShift, pressed: true))
        XCTAssertEqual(r, ModifierTransition(modifier: .rightShift, pressed: true))
        XCTAssertEqual(tracker.currentState, [.leftShift, .rightShift])
    }

    /// Releasing one of two held ⌘ keys: the coarse mask stays set because the
    /// other side is still down, so only the device-side bit can tell them
    /// apart.
    func testReleasingOneSideWhileTheOtherIsHeld() {
        var tracker = ModifierTracker()
        _ = tracker.handle(modifierKeyCode: 0x37, rawFlags: Flag.cmdMask | Flag.lCmd)
        _ = tracker.handle(modifierKeyCode: 0x36, rawFlags: Flag.cmdMask | Flag.lCmd | Flag.rCmd)
        XCTAssertEqual(tracker.currentState, [.leftMeta, .rightMeta])

        let release = tracker.handle(modifierKeyCode: 0x37, rawFlags: Flag.cmdMask | Flag.rCmd)
        XCTAssertEqual(release, ModifierTransition(modifier: .leftMeta, pressed: false))
        XCTAssertEqual(tracker.currentState, .rightMeta,
                       "right ⌘ must stay held; the coarse mask alone could not show this")
    }

    // MARK: - The ⌘Tab regression

    /// Reported from real use: ⌘Tab away from Regi, release ⌘ in another app,
    /// and every subsequent ⌘ was inverted until reconnecting.
    ///
    /// The tracker used to toggle on the keycode and ignore the flags, so the
    /// missed release left it believing ⌘ was down; the next press toggled
    /// that to "released" and sent a release to the host. Reading the flag bit
    /// makes the next event re-synchronise instead.
    func testMissedReleaseOutsideTheWindowDoesNotInvertTheNextPress() {
        var tracker = ModifierTracker()
        _ = tracker.handle(modifierKeyCode: 0x37, rawFlags: Flag.cmdMask | Flag.lCmd)
        XCTAssertEqual(tracker.currentState, .leftMeta)

        // ⌘Tab: focus goes elsewhere and the release is never delivered to us.

        // Back in the window, the user presses ⌘ again. The flags say it is
        // down, and that is the truth regardless of what we believed.
        let next = tracker.handle(modifierKeyCode: 0x37, rawFlags: Flag.cmdMask | Flag.lCmd)
        XCTAssertNil(next, "already believed down and still down — no spurious transition")
        XCTAssertEqual(tracker.currentState, .leftMeta)

        // Releasing it now correctly emits a release.
        let release = tracker.handle(modifierKeyCode: 0x37, rawFlags: 0)
        XCTAssertEqual(release, ModifierTransition(modifier: .leftMeta, pressed: false),
                       "the release must reach the host, or ⌘ stays stuck there")
        XCTAssertTrue(tracker.currentState.isEmpty)
    }

    /// The mirror case: we missed a *press*, so the first event we see says
    /// down when we believed up. That must emit a press, not be swallowed.
    func testMissedPressOutsideTheWindowResynchronises() {
        var tracker = ModifierTracker()
        let t = tracker.handle(modifierKeyCode: 0x38, rawFlags: Flag.shiftMask | Flag.lShift)
        XCTAssertEqual(t, ModifierTransition(modifier: .leftShift, pressed: true))
    }

    /// A redundant event — flags already agreeing with our state — must not
    /// produce a phantom press or release on the host.
    func testRedundantEventEmitsNothing() {
        var tracker = ModifierTracker()
        _ = tracker.handle(modifierKeyCode: 0x3B, rawFlags: Flag.ctrlMask | Flag.lCtrl)

        XCTAssertNil(tracker.handle(modifierKeyCode: 0x3B, rawFlags: Flag.ctrlMask | Flag.lCtrl),
                     "flags already agree with our state — emitting here would send "
                     + "a phantom press to the host")

        XCTAssertEqual(tracker.handle(modifierKeyCode: 0x3B, rawFlags: 0),
                       ModifierTransition(modifier: .leftControl, pressed: false),
                       "a genuine change still emits")
    }

    func testNonModifierKeyCodesAreIgnored() {
        var tracker = ModifierTracker()
        XCTAssertNil(tracker.handle(modifierKeyCode: 0x39, rawFlags: 0x0001_0000)) // caps lock
        XCTAssertNil(tracker.handle(modifierKeyCode: 0x00, rawFlags: 0))           // 'a'
        XCTAssertTrue(tracker.currentState.isEmpty)
    }

    func testResetClearsEverything() {
        var tracker = ModifierTracker()
        _ = tracker.handle(modifierKeyCode: 0x3A, rawFlags: Flag.altMask | Flag.lAlt)
        _ = tracker.handle(modifierKeyCode: 0x3E,
                           rawFlags: Flag.altMask | Flag.lAlt | Flag.ctrlMask | Flag.rCtrl)
        XCTAssertFalse(tracker.currentState.isEmpty)
        tracker.reset()
        XCTAssertTrue(tracker.currentState.isEmpty)
    }

    func testAllEightModifiersMapToDistinctBits() {
        let keyCodes: [UInt16] = [0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E]
        let bits = keyCodes.compactMap { ModifierTracker.deviceFlagBit(forKeyCode: $0) }
        XCTAssertEqual(bits.count, 8)
        XCTAssertEqual(Set(bits).count, 8, "each side of each modifier needs its own bit")
        let mods = keyCodes.compactMap { ModifierTracker.modifier(forKeyCode: $0) }
        XCTAssertEqual(Set(mods).count, 8)
    }
}
