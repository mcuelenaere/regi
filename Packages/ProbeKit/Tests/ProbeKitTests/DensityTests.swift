import XCTest
@testable import ProbeKit

/// Sizing the sliding window is the decision this whole design hangs on: it
/// sets how often the driver must land a successful read, and an undersized
/// window turns a missed read into a failed run.
///
/// These numbers are measured against deliberately non-repetitive fixtures. An
/// earlier cut used cyclic ones, LZFSE compressed 5,000 events into 384 bytes,
/// and the resulting "1 B/event" would have sized the symbol far too small.
final class DensityTests: XCTestCase {
    /// Measured QR capacity per EC level, from `qr-spike capacity`. Level H is
    /// the operative one — verified through the real rig at 240/240.
    static let capacityH = 1273
    static let capacityL = 2953

    /// The largest scenario in the catalogue: 40 alternating key pairs, down
    /// and up, all keyboard traffic. If this fits, everything fits.
    static let burstEvents = 160

    func testLargestCatalogueScenarioFitsOneLevelHCode() throws {
        let events = Fixtures.typing(events: Self.burstEvents)
        let size = try FrameCodec.encode(Fixtures.frame(events)).count
        print("""

        ── burst-ordering scenario (\(Self.burstEvents) keyboard events) ──
        \(size) bytes  (\(String(format: "%.2f", Double(size) / Double(events.count))) B/event)
        level H capacity: \(Self.capacityH) B  → \(size <= Self.capacityH ? "FITS" : "OVERFLOWS")
        """)
        XCTAssertLessThanOrEqual(
            size, Self.capacityH,
            "The burst scenario must fit one level-H code. Shard to a 2x2 grid "
            + "before weakening error correction — the video path needs the EC more."
        )
    }

    func testMeasuredDensityByTrafficShape() throws {
        var rows: [(String, Int, Int)] = []
        for (name, events) in [("typing", Fixtures.typing(events: 200)),
                               ("drag", Fixtures.drag(events: 200)),
                               ("mixed", Fixtures.mixed(count: 200))] {
            rows.append((name, events.count, try FrameCodec.encode(Fixtures.frame(events)).count))
        }
        print("\n── density by traffic shape (200 events each) ──")
        for (name, n, bytes) in rows {
            let per = Double(bytes) / Double(n)
            print(String(format: "  %-7s %5d B  %.2f B/event  → window of ~%d events at level H",
                         (name as NSString).utf8String!, bytes, per,
                         Int(Double(Self.capacityH) / per)))
        }
        // Guards the sizing assumption rather than a specific byte count: if
        // density regresses past this, the window shrinks below the burst
        // scenario and the budget needs revisiting.
        for (name, n, bytes) in rows {
            XCTAssertLessThan(Double(bytes) / Double(n), 12.0,
                              "\(name) density regressed; re-check the window budget")
            XCTAssertGreaterThan(n, 0)
        }
    }

    // MARK: - The cap

    /// The symbol must never grow: a higher QR version means smaller modules at
    /// the same band size, and the loop breaks silently.
    func testEncodeCappedNeverExceedsTheBudget() throws {
        let huge = Fixtures.frame(Fixtures.mixed(count: 5000))
        let (data, encoded) = try FrameCodec.encodeCapped(huge)

        XCTAssertLessThanOrEqual(data.count, FrameCodec.defaultMaxBytes)
        XCTAssertLessThan(encoded.events.count, huge.events.count, "should have trimmed")
        XCTAssertEqual(encoded.events.last?.seq, huge.events.last?.seq,
                       "trimming drops the OLDEST events; the newest must survive")
        print("\n── capped encode ──\n5000 events → trimmed to \(encoded.events.count) "
              + "in \(data.count) B (budget \(FrameCodec.defaultMaxBytes) B)")
    }

    /// Trimming has to be visible to the driver, or it asserts over a partial
    /// record and reports a pass it did not earn.
    func testTrimmingRaisesOldestSeqSoGapsAreDetectable() throws {
        let huge = Fixtures.frame(Fixtures.mixed(count: 5000))
        let (_, encoded) = try FrameCodec.encodeCapped(huge)

        XCTAssertGreaterThan(encoded.oldestSeqInWindow, huge.oldestSeqInWindow)
        XCTAssertEqual(encoded.oldestSeqInWindow, encoded.events.first?.seq)

        let staleDriverSeq = huge.events.first!.seq
        XCTAssertLessThan(staleDriverSeq, encoded.oldestSeqInWindow,
                          "this comparison is the driver's gap check")
    }

    func testBurstScenarioIsNotTrimmedAtAll() throws {
        let burst = Fixtures.frame(Fixtures.typing(events: Self.burstEvents))
        let (_, encoded) = try FrameCodec.encodeCapped(burst)
        XCTAssertEqual(encoded.events.count, Self.burstEvents,
                       "the largest catalogue scenario must survive the cap untrimmed")
    }

    // MARK: - Container

    func testCompressionActuallyHelpsOnRealisticFrames() throws {
        let encoded = try FrameCodec.encode(Fixtures.frame(Fixtures.mixed(count: 200)))
        XCTAssertEqual(encoded.first, FrameCodec.Format.lzfseProtobuf.rawValue,
                       "LZFSE should win on a 200-event frame; if it stops winning, "
                       + "the density budget needs recomputing")
    }

    func testTinyFramesShipUncompressed() throws {
        // LZFSE on a handful of bytes is larger than the input; the container's
        // format byte exists so that case does not silently cost capacity.
        let encoded = try FrameCodec.encode(Fixtures.frame(Fixtures.typing(events: 2)))
        XCTAssertEqual(encoded.first, FrameCodec.Format.rawProtobuf.rawValue)
    }
}
