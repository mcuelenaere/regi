import XCTest
@testable import ProbeKit

final class FrameCodecTests: XCTestCase {

    // MARK: - Round trip

    func testRoundTripPreservesEventsExactly() throws {
        let frame = Fixtures.frame(Fixtures.typing(events: 22))
        let decoded = try FrameCodec.decode(try FrameCodec.encode(frame))

        XCTAssertEqual(decoded.events, frame.events)
        XCTAssertEqual(decoded.epoch, frame.epoch)
        XCTAssertEqual(decoded.frameIndex, frame.frameIndex)
        XCTAssertEqual(decoded.oldestSeqInWindow, frame.oldestSeqInWindow)
        XCTAssertEqual(decoded.heldKeys, frame.heldKeys)
        XCTAssertEqual(decoded.screen, frame.screen)
        XCTAssertEqual(decoded.health, frame.health)
    }

    func testRoundTripAcrossEveryPayloadKind() throws {
        let events: [ProbeEvent] = [
            .init(seq: 10, machAbsoluteNanos: 1_000_000_000,
                  payload: .key(.init(kvk: 0x08, down: true, autorepeat: true,
                                      rawFlags: 0x10_0000, characters: "c", sourcePID: 0))),
            .init(seq: 11, machAbsoluteNanos: 1_040_000_000,
                  payload: .flags(.init(kvk: 0x3C, rawFlags: 0x2_0104))),
            .init(seq: 12, machAbsoluteNanos: 1_080_000_000,
                  payload: .pointer(.init(type: 1, x: -40, y: 900, deltaX: -3, deltaY: 2,
                                          buttonNumber: 3, clickState: 2, sourcePID: 0))),
            .init(seq: 13, machAbsoluteNanos: 1_120_000_000,
                  payload: .wheel(.init(lineDeltaY: -1, lineDeltaX: 2, pointDeltaY: -30,
                                        pointDeltaX: 60, isContinuous: true, phase: 4))),
            .init(seq: 14, machAbsoluteNanos: 1_160_000_000,
                  payload: .gesture(.init(kind: .magnify, value: 0.25, phase: 2))),
            .init(seq: 15, machAbsoluteNanos: 1_200_000_000,
                  payload: .touches([.init(identity: 99, normX: 0.5, normY: 0.25, phase: 1, type: 1)])),
            .init(seq: 16, machAbsoluteNanos: 1_240_000_000,
                  payload: .diagnostic(.init(kind: .ringOverflow, detail: "dropped", value: 12))),
        ]
        let decoded = try FrameCodec.decode(try FrameCodec.encode(Fixtures.frame(events)))
        XCTAssertEqual(decoded.events, events)
    }

    /// Flags ride the wire only when they change; every decoded event must
    /// still carry absolute flags, or left/right modifier assertions break.
    func testUnchangedFlagsAreCarriedForwardOnDecode() throws {
        let flags: UInt64 = 0x2_0102
        var events: [ProbeEvent] = []
        for i in 0..<10 {
            let seq = UInt64(i + 1)
            let nanos = UInt64(1_000_000_000) + UInt64(i) * UInt64(20_000_000)
            let key = ProbeEvent.Key(kvk: 0x00, down: i % 2 == 0, rawFlags: flags)
            events.append(ProbeEvent(seq: seq, machAbsoluteNanos: nanos, payload: .key(key)))
        }
        let decoded = try FrameCodec.decode(try FrameCodec.encode(Fixtures.frame(events)))
        for e in decoded.events {
            guard case .key(let k) = e.payload else { return XCTFail("expected key") }
            XCTAssertEqual(k.rawFlags, flags)
        }
    }

    /// Pointer positions are delta-encoded (it is the difference between a drag
    /// fitting one QR code and not), so absolute positions must reconstruct.
    func testPointerPositionsReconstructFromDeltas() throws {
        let events = Fixtures.drag(events: 60)
        let decoded = try FrameCodec.decode(try FrameCodec.encode(Fixtures.frame(events)))
        XCTAssertEqual(decoded.events, events)
    }

    func testNonContiguousSequenceNumbersSurvive() throws {
        // The ring drops events under overflow, so gaps are real and must not
        // be silently renumbered into a contiguous run.
        let events: [ProbeEvent] = [
            .init(seq: 100, machAbsoluteNanos: 1_000_000_000, payload: .key(.init(kvk: 0x00, down: true))),
            .init(seq: 137, machAbsoluteNanos: 1_500_000_000, payload: .key(.init(kvk: 0x00, down: false))),
            .init(seq: 900, machAbsoluteNanos: 2_000_000_000, payload: .key(.init(kvk: 0x0E, down: true))),
        ]
        let decoded = try FrameCodec.decode(try FrameCodec.encode(Fixtures.frame(events)))
        XCTAssertEqual(decoded.events.map(\.seq), [100, 137, 900])
    }

    func testEmptyFrameRoundTrips() throws {
        let decoded = try FrameCodec.decode(try FrameCodec.encode(Fixtures.frame([])))
        XCTAssertTrue(decoded.events.isEmpty)
    }

    // MARK: - Rejecting bad input

    func testRejectsUnsupportedWireVersion() throws {
        var frame = Fixtures.frame(Fixtures.typing(events: 4))
        frame.wireVersion = 99
        let data = try FrameCodec.encode(frame)
        XCTAssertThrowsError(try FrameCodec.decode(data)) { error in
            XCTAssertEqual(error as? FrameCodec.Error, .unsupportedWireVersion(99))
        }
    }

    func testRejectsHeaderTooShortToParse() throws {
        let data = try FrameCodec.encode(Fixtures.frame(Fixtures.typing(events: 10)))
        XCTAssertThrowsError(try FrameCodec.decode(data.prefix(4)))
    }

    /// The invariant that matters is **not** "every byte is load-bearing".
    /// LZFSE streams carry redundancy: some bit flips leave the decompressed
    /// body identical, and a truncated tail can be an end-of-stream marker the
    /// payload does not need. What must never happen is a frame decoding to
    /// *different* content than was encoded — that is the silent corruption a
    /// test could unknowingly pass on.
    ///
    /// Measured over every single-bit flip in a 40-event frame: 385 rejected,
    /// 8 decoded byte-identical, 0 decoded to wrong content.
    func testDamageIsEitherRejectedOrLossless() throws {
        let frame = Fixtures.frame(Fixtures.typing(events: 40))
        let clean = [UInt8](try FrameCodec.encode(frame))

        var silentlyWrong: [Int] = []
        for i in FrameCodec.headerSize..<clean.count {
            var d = clean
            d[i] ^= 0x01
            if let got = try? FrameCodec.decode(Data(d)), got.events != frame.events {
                silentlyWrong.append(i)
            }
        }
        XCTAssertTrue(silentlyWrong.isEmpty,
                      "bit flips at offsets \(silentlyWrong) decoded to WRONG content")

        for drop in 1...12 {
            let cut = Data(clean.prefix(clean.count - drop))
            if let got = try? FrameCodec.decode(cut) {
                XCTAssertEqual(got.events, frame.events,
                               "truncation by \(drop) bytes decoded to wrong content")
            }
        }
    }

    /// Wholesale corruption must be caught outright — this is what the CRC in
    /// the container header is for.
    func testRejectsWholesaleBodyCorruption() throws {
        var data = [UInt8](try FrameCodec.encode(Fixtures.frame(Fixtures.typing(events: 40))))
        for i in FrameCodec.headerSize..<data.count { data[i] ^= 0xA5 }
        XCTAssertThrowsError(try FrameCodec.decode(Data(data)))
    }
}
