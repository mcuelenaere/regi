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
