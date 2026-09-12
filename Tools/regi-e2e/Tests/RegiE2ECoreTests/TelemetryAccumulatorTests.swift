import ProbeKit
import XCTest
@testable import RegiE2ECore

final class TelemetryAccumulatorTests: XCTestCase {
    private func frame(_ index: UInt32, seqs: ClosedRange<UInt64>,
                       oldest: UInt64? = nil, epoch: UInt32 = 1) -> TelemetryFrame {
        TelemetryFrame(
            epoch: epoch, frameIndex: index, probeMonotonicNanos: UInt64(index) * 1_000_000,
            oldestSeqInWindow: oldest ?? seqs.lowerBound,
            health: .init(tapEnabled: true, runActive: true, accessibilityGranted: true),
            events: seqs.map {
                ProbeEvent(seq: $0, machAbsoluteNanos: $0 * 1_000_000,
                           payload: .key(.init(kvk: 0x00, down: $0 % 2 == 0)))
            })
    }

    func testOverlappingWindowsYieldEachEventExactlyOnce() throws {
        var acc = TelemetryAccumulator()
        XCTAssertEqual(try acc.ingest(frame(1, seqs: 1...10)).map(\.seq), Array(1...10))
        // Heavy overlap is the normal case, not an error.
        XCTAssertEqual(try acc.ingest(frame(2, seqs: 5...14)).map(\.seq), Array(11...14))
        XCTAssertEqual(acc.totalEvents, 14)
    }

    /// The probe holds each code for a dwell interval, so re-reads are expected.
    func testRereadingTheSameFrameYieldsNothing() throws {
        var acc = TelemetryAccumulator()
        _ = try acc.ingest(frame(1, seqs: 1...10))
        XCTAssertTrue(try acc.ingest(frame(1, seqs: 1...10)).isEmpty)
        XCTAssertEqual(acc.totalEvents, 10)
    }

    /// The point of the whole mechanism: a hole in the record must fail loudly
    /// rather than let a run assert over partial evidence.
    func testGapIsDetectedAndThrows() throws {
        var acc = TelemetryAccumulator()
        _ = try acc.ingest(frame(1, seqs: 1...10))
        XCTAssertThrowsError(try acc.ingest(frame(2, seqs: 40...50))) { error in
            XCTAssertEqual(error as? TelemetryAccumulator.Fault,
                           .gap(expectedFrom: 11, oldestAvailable: 40, lost: 29))
        }
    }

    /// A window that still reaches back to what we have is not a gap, even
    /// though its newest events are far ahead.
    func testContiguousWindowIsNotAGap() throws {
        var acc = TelemetryAccumulator()
        _ = try acc.ingest(frame(1, seqs: 1...10))
        XCTAssertEqual(try acc.ingest(frame(2, seqs: 11...30, oldest: 11)).count, 20)
    }

    func testProbeRestartIsDetected() throws {
        var acc = TelemetryAccumulator()
        _ = try acc.ingest(frame(1, seqs: 1...10, epoch: 7))
        XCTAssertThrowsError(try acc.ingest(frame(1, seqs: 1...10, epoch: 8))) { error in
            XCTAssertEqual(error as? TelemetryAccumulator.Fault,
                           .epochChanged(from: 7, to: 8))
        }
    }

    func testFirstFrameNeverReportsAGap() throws {
        var acc = TelemetryAccumulator()
        // Joining a probe that has been running for a while is normal.
        XCTAssertEqual(try acc.ingest(frame(9, seqs: 5000...5010)).count, 11)
    }
}
