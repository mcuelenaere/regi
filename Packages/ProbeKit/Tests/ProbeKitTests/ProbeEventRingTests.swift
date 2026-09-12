import XCTest
@testable import ProbeKit

/// The ring's drop accounting feeds `oldestSeqInWindow`, which is what lets the
/// driver detect that evidence fell out of the window and fail the run. Getting
/// it wrong means a test passes over a partial record.
final class ProbeEventRingTests: XCTestCase {
    private func push(_ ring: ProbeEventRing, _ n: Int, from: UInt16 = 0) {
        for i in 0..<n {
            ring.append(machAbsoluteNanos: UInt64(i + 1) * 1_000_000,
                        payload: .key(.init(kvk: from &+ UInt16(i % 16), down: i % 2 == 0)))
        }
    }

    func testSequenceNumbersAreContiguousAndStartAtOne() {
        let ring = ProbeEventRing(capacity: 16)
        push(ring, 5)
        XCTAssertEqual(ring.recent(10).events.map(\.seq), [1, 2, 3, 4, 5])
        XCTAssertEqual(ring.nextSeq, 6)
    }

    func testRecentReturnsOldestFirst() {
        let ring = ProbeEventRing(capacity: 16)
        push(ring, 5)
        let seqs = ring.recent(3).events.map(\.seq)
        XCTAssertEqual(seqs, [3, 4, 5], "recent(n) must return the newest n, oldest-first")
    }

    func testOverflowDropsOldestAndCountsIt() {
        let ring = ProbeEventRing(capacity: 8)
        push(ring, 20)
        let (events, oldest, dropped) = ring.recent(100)

        XCTAssertEqual(events.count, 8, "capacity is the hard bound")
        XCTAssertEqual(events.map(\.seq), Array(13...20), "newest survive")
        XCTAssertEqual(dropped, 12)
        XCTAssertEqual(oldest, 13, "oldestAvailableSeq must name the first surviving event")
    }

    /// Sequence numbers must never be reused: the driver scopes assertions to
    /// half-open seq ranges, and a reused seq would silently merge two records.
    func testSequenceNumbersAreNeverReusedAcrossOverflow() {
        let ring = ProbeEventRing(capacity: 4)
        push(ring, 100)
        XCTAssertEqual(ring.nextSeq, 101)
        XCTAssertEqual(ring.recent(4).events.map(\.seq), [97, 98, 99, 100])
    }

    func testResetKeepsSequenceMovingForward() {
        let ring = ProbeEventRing(capacity: 8)
        push(ring, 5)
        ring.reset()
        XCTAssertTrue(ring.recent(10).events.isEmpty)
        XCTAssertEqual(ring.dropped, 0)
        push(ring, 1)
        XCTAssertEqual(ring.recent(10).events.map(\.seq), [6],
                       "reset clears storage but must not rewind seq — a driver "
                       + "holding an older seq has to be able to tell")
    }

    func testConcurrentAppendsProduceUniqueSequenceNumbers() {
        let ring = ProbeEventRing(capacity: 8192)
        let group = DispatchGroup()
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) {
                for _ in 0..<500 {
                    ring.append(machAbsoluteNanos: 1, payload: .key(.init(kvk: 0, down: true)))
                }
            }
        }
        group.wait()
        XCTAssertEqual(ring.nextSeq, 4001)
        let seqs = ring.recent(8192).events.map(\.seq)
        XCTAssertEqual(Set(seqs).count, seqs.count, "no duplicate sequence numbers under contention")
        XCTAssertEqual(seqs, seqs.sorted(), "recent() must be ordered")
    }
}
