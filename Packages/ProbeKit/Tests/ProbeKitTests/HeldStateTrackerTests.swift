import XCTest
@testable import ProbeKit

/// These are the bug classes the whole harness exists to catch, so they are
/// tested against the tracker directly rather than only end to end.
final class HeldStateTrackerTests: XCTestCase {
    private func key(_ seq: UInt64, _ kvk: UInt16, down: Bool,
                     autorepeat: Bool = false, nanos: UInt64? = nil) -> ProbeEvent {
        ProbeEvent(seq: seq, machAbsoluteNanos: nanos ?? seq * 10_000_000,
                   payload: .key(.init(kvk: kvk, down: down, autorepeat: autorepeat)))
    }

    func testCleanPressReleaseLeavesNothingHeld() {
        var t = HeldStateTracker()
        t.ingest(key(1, 0x00, down: true))
        t.ingest(key(2, 0x00, down: false))
        t.finish()
        XCTAssertTrue(t.nothingHeld)
        XCTAssertTrue(t.counters.isClean)
    }

    /// The stuck-modifier bug, caught directly.
    func testKeyStillHeldAtEndIsAViolation() {
        var t = HeldStateTracker()
        t.ingest(key(1, 0x38, down: true, nanos: 1_000_000_000))
        let v = t.finish(atNanos: 3_000_000_000)

        XCTAssertEqual(t.counters.stuckAtEnd, 1)
        XCTAssertEqual(v.count, 1)
        guard case .stuckAtEnd(let kvk, let held) = v[0].kind else { return XCTFail() }
        XCTAssertEqual(kvk, 0x38)
        XCTAssertEqual(held, 2_000_000_000)
        XCTAssertTrue(v[0].description.contains("⇧L"), "should name the key readably")
    }

    /// A release with no press almost always means a press was lost in transit.
    func testReleaseWithoutPressIsAViolation() {
        var t = HeldStateTracker()
        let v = t.ingest(key(1, 0x08, down: false))
        XCTAssertEqual(t.counters.upWithoutDown, 1)
        XCTAssertEqual(v.count, 1)
        XCTAssertTrue(t.nothingHeld)
    }

    /// OS autorepeat is the OS doing its job and must not be confused with the
    /// client double-sending a press.
    func testAutorepeatCountsAsRepeatNotDuplicate() {
        var t = HeldStateTracker()
        t.ingest(key(1, 0x25, down: true))
        for i in 2...6 { t.ingest(key(UInt64(i), 0x25, down: true, autorepeat: true)) }
        t.ingest(key(7, 0x25, down: false))
        t.finish()

        XCTAssertEqual(t.counters.duplicateDown, 0)
        XCTAssertEqual(t.counters.upWithoutDown, 0)
        XCTAssertTrue(t.nothingHeld)
    }

    func testNonRepeatPressWhileHeldIsADuplicate() {
        var t = HeldStateTracker()
        t.ingest(key(1, 0x25, down: true))
        let v = t.ingest(key(2, 0x25, down: true))
        XCTAssertEqual(t.counters.duplicateDown, 1)
        XCTAssertEqual(v.count, 1)
    }

    /// flagsChanged is a toggle: the keycode says which modifier, and whether
    /// it is now down comes from the tracker's own state.
    func testFlagsChangedTogglesHeldState() {
        var t = HeldStateTracker()
        t.ingest(.init(seq: 1, machAbsoluteNanos: 1, payload: .flags(.init(kvk: 0x37, rawFlags: 0x100108))))
        XCTAssertFalse(t.nothingHeld)
        t.ingest(.init(seq: 2, machAbsoluteNanos: 2, payload: .flags(.init(kvk: 0x37, rawFlags: 0))))
        XCTAssertTrue(t.nothingHeld)
    }

    /// Left and right modifiers are distinct keycodes and must not collapse —
    /// this is the single most valuable ModifierTracker regression check.
    func testLeftAndRightModifiersTrackIndependently() {
        var t = HeldStateTracker()
        t.ingest(.init(seq: 1, machAbsoluteNanos: 1, payload: .flags(.init(kvk: 0x38, rawFlags: 0x20102))))
        t.ingest(.init(seq: 2, machAbsoluteNanos: 2, payload: .flags(.init(kvk: 0x3C, rawFlags: 0x20104))))
        XCTAssertEqual(t.heldKeys.count, 2)
        t.ingest(.init(seq: 3, machAbsoluteNanos: 3, payload: .flags(.init(kvk: 0x38, rawFlags: 0x20104))))
        XCTAssertEqual(Array(t.heldKeys.keys), [0x3C])
    }

    /// On a dedicated target, an injected event means something other than the
    /// KVM produced input and the run is contaminated.
    func testSyntheticSourceIsFlagged() {
        var t = HeldStateTracker()
        let e = ProbeEvent(seq: 1, machAbsoluteNanos: 1,
                           payload: .key(.init(kvk: 0x00, down: true, sourcePID: 4242)))
        let v = t.ingest(e)
        XCTAssertEqual(t.counters.syntheticSourceEvents, 1)
        XCTAssertTrue(v.contains { if case .syntheticSource(let p) = $0.kind { return p == 4242 }; return false })
    }

    func testTimestampGoingBackwardsIsFlagged() {
        var t = HeldStateTracker()
        t.ingest(key(1, 0x00, down: true, nanos: 5_000_000_000))
        t.ingest(key(2, 0x00, down: false, nanos: 1_000_000_000))
        XCTAssertEqual(t.counters.nonMonotonicTimestamp, 1)
    }

    func testHoldDurationIsMeasurable() {
        var t = HeldStateTracker()
        t.ingest(key(1, 0x00, down: true, nanos: 1_000_000_000))
        XCTAssertEqual(t.holdDuration(of: 0x00, atNanos: 1_700_000_000), 700_000_000)
        XCTAssertNil(t.holdDuration(of: 0x01, atNanos: 1_700_000_000))
    }
}

extension HeldStateTrackerTests {
    /// Measured on a real session tap: `CGEventGetTimestamp` interleaves out of
    /// order across event sources by ~12 ms in ordinary use. Flagging that as a
    /// violation would fail every real run, so it is counted and nothing more.
    func testBackwardsTimestampIsCountedButNotAViolation() {
        var t = HeldStateTracker()
        t.ingest(key(1, 0x00, down: true, nanos: 5_000_000_000))
        let v = t.ingest(key(2, 0x01, down: true, nanos: 4_988_000_000))

        XCTAssertEqual(t.counters.nonMonotonicTimestamp, 1, "still worth counting")
        XCTAssertTrue(v.isEmpty, "must not be reported as a violation")
        XCTAssertTrue(t.counters.isClean, "must not make a run look dirty")
    }

    /// Ordering assertions rely on seq, which is assigned on arrival, so an
    /// inverted timestamp must not disturb held-state tracking.
    func testHeldStateIsUnaffectedByTimestampInversion() {
        var t = HeldStateTracker()
        t.ingest(key(1, 0x38, down: true, nanos: 5_000_000_000))
        t.ingest(key(2, 0x00, down: true, nanos: 4_988_000_000))
        t.ingest(key(3, 0x00, down: false, nanos: 5_010_000_000))
        t.ingest(key(4, 0x38, down: false, nanos: 5_020_000_000))
        t.finish()
        XCTAssertTrue(t.nothingHeld)
        XCTAssertEqual(t.counters.upWithoutDown, 0)
    }
}

extension HeldStateTrackerTests {
    private func flags(_ seq: UInt64, _ kvk: UInt16, _ raw: UInt64) -> ProbeEvent {
        ProbeEvent(seq: seq, machAbsoluteNanos: seq * 1_000_000,
                   payload: .flags(.init(kvk: kvk, rawFlags: raw)))
    }

    /// Modifier state comes from the flag bits, not from counting transitions.
    func testModifierStateIsReadFromFlagsNotToggled() {
        var t = HeldStateTracker()
        t.ingest(flags(1, 0x37, 0x100108))   // left command down
        XCTAssertEqual(Array(t.heldKeys.keys), [0x37])
        t.ingest(flags(2, 0x37, 0x100))      // released
        XCTAssertTrue(t.nothingHeld)
    }

    /// The reason for reading flags: a lost event must not corrupt state
    /// permanently. With toggle parity a single miss inverts everything after.
    func testStateResynchronisesAfterALostEvent() {
        var t = HeldStateTracker()
        t.ingest(flags(1, 0x38, 0x20102))    // left shift down
        // ...its release never arrives (dropped from the window)...
        t.ingest(flags(3, 0x38, 0x20102))    // and it is pressed again
        XCTAssertEqual(Array(t.heldKeys.keys), [0x38], "still held — correct")
        t.ingest(flags(4, 0x38, 0x100))      // now released
        XCTAssertTrue(t.nothingHeld, "a flag bit re-synchronises; parity would be inverted here")
    }

    /// Left and right carry different bits, so a same-side release must not
    /// clear the other side.
    func testLeftAndRightModifiersUseDistinctBits() {
        var t = HeldStateTracker()
        t.ingest(flags(1, 0x38, 0x20102))               // left shift down
        t.ingest(flags(2, 0x3C, 0x20106))               // right shift down too
        XCTAssertEqual(Set(t.heldKeys.keys), [0x38, 0x3C])
        t.ingest(flags(3, 0x38, 0x20104))               // left released, right still set
        XCTAssertEqual(Set(t.heldKeys.keys), [0x3C])
    }

    func testUnknownModifierKeycodeStillToggles() {
        var t = HeldStateTracker()
        t.ingest(flags(1, 0x7F, 0))
        XCTAssertEqual(Array(t.heldKeys.keys), [0x7F])
        t.ingest(flags(2, 0x7F, 0))
        XCTAssertTrue(t.nothingHeld)
    }
}
