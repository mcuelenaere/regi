import XCTest
@testable import ProbeKit

/// The probe's job is to say whether input arrived intact, so a violation it
/// invents is worse than one it misses.
final class RingLiveStateTests: XCTestCase {
    private func down(_ button: Int) -> ProbeEvent.Payload {
        .pointer(.init(type: button == 0 ? 1 : 25, x: 10, y: 10,
                       buttonNumber: UInt32(button), clickState: 1))
    }
    private func up(_ button: Int) -> ProbeEvent.Payload {
        .pointer(.init(type: button == 0 ? 2 : 26, x: 10, y: 10,
                       buttonNumber: UInt32(button), clickState: 1))
    }
    private func move() -> ProbeEvent.Payload {
        .pointer(.init(type: 5, x: 10, y: 10, deltaX: 1))
    }

    /// A press that has aged out of the ring must not turn its release into a
    /// violation. This is the bug the old replay-over-`recent(n)` had.
    func testPressEvictedFromRingDoesNotFabricateAViolation() {
        let ring = ProbeEventRing(capacity: 8)
        ring.append(machAbsoluteNanos: 1, payload: down(0))
        // Push the press out of the ring with unrelated traffic, then release.
        for i in 0..<16 {
            ring.append(machAbsoluteNanos: UInt64(10 + i), payload: move())
        }
        ring.append(machAbsoluteNanos: 100, payload: up(0))

        let live = ring.liveState()
        XCTAssertEqual(live.counters.upWithoutDown, 0,
                       "the press was captured; that it no longer fits in the ring is not a violation")
        XCTAssertTrue(live.heldButtons.isEmpty, "the release should have cleared the hold")
        XCTAssertGreaterThan(live.counters.droppedByRing, 0,
                             "the ring did drop events, and should still say so")

        // And the old approach, for contrast: replaying the resident window
        // alone sees a release with no press.
        let (events, _, _) = ring.recent(300)
        var replayed = HeldStateTracker()
        for e in events { replayed.ingest(e) }
        XCTAssertEqual(replayed.counters.upWithoutDown, 1,
                       "replaying the window is exactly what fabricated the violation")
    }

    /// A genuine unmatched release must still be reported.
    func testGenuineUnmatchedReleaseIsStillCounted() {
        let ring = ProbeEventRing(capacity: 64)
        ring.append(machAbsoluteNanos: 1, payload: up(0))
        XCTAssertEqual(ring.liveState().counters.upWithoutDown, 1)
    }

    /// Counters describe the whole run, not the resident window.
    func testCountersSurviveRingTurnover() {
        let ring = ProbeEventRing(capacity: 8)
        ring.append(machAbsoluteNanos: 1, payload: up(2))   // genuine violation
        for i in 0..<50 {
            ring.append(machAbsoluteNanos: UInt64(10 + i), payload: move())
        }
        XCTAssertEqual(ring.liveState().counters.upWithoutDown, 1,
                       "a violation from early in the run must not be forgotten")
    }

    func testResetClearsCumulativeState() {
        let ring = ProbeEventRing(capacity: 8)
        ring.append(machAbsoluteNanos: 1, payload: up(0))
        XCTAssertEqual(ring.liveState().counters.upWithoutDown, 1)
        ring.reset()
        XCTAssertEqual(ring.liveState().counters.upWithoutDown, 0)
        XCTAssertTrue(ring.liveState().violations.isEmpty)
    }
}

/// `dropped` must mean "a reader never saw these", not "the ring wrapped".
final class RingDropAccountingTests: XCTestCase {
    private func move() -> ProbeEvent.Payload {
        .pointer(.init(type: 5, x: 1, y: 1, deltaX: 1))
    }

    /// A reader keeping up sees every event; the ring wrapping underneath it
    /// is normal and must not be reported as loss. Before this, `dropped`
    /// began climbing the moment the ring first wrapped and never stopped, so
    /// any run longer than the capacity looked like it was losing input.
    func testReaderKeepingUpSeesNoDrops() {
        let ring = ProbeEventRing(capacity: 16)
        for i in 0..<200 {
            ring.append(machAbsoluteNanos: UInt64(i), payload: move())
            _ = ring.recent(16)   // a driver reading every event
        }
        XCTAssertEqual(ring.liveState().counters.droppedByRing, 0,
                       "the ring wrapped 12 times over, but nothing was missed")
    }

    /// A reader that never reads does lose events, and that must be reported.
    func testUnreadEventsAreCountedAsDropped() {
        let ring = ProbeEventRing(capacity: 16)
        for i in 0..<50 {
            ring.append(machAbsoluteNanos: UInt64(i), payload: move())
        }
        XCTAssertEqual(ring.liveState().counters.droppedByRing, 34,
                       "50 events into a 16-slot ring with no reader: 34 fell out unseen")
    }

    /// A reader that falls behind loses only what it actually missed.
    func testPartialReaderLosesOnlyWhatItMissed() {
        let ring = ProbeEventRing(capacity: 16)
        for i in 0..<16 { ring.append(machAbsoluteNanos: UInt64(i), payload: move()) }
        _ = ring.recent(16)                       // caught up: seen 1...16
        for i in 16..<48 { ring.append(machAbsoluteNanos: UInt64(i), payload: move()) }
        XCTAssertEqual(ring.liveState().counters.droppedByRing, 16,
                       "32 more events arrived, the ring held the last 16, so 16 went unseen")
    }
}
