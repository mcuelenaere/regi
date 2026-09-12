import XCTest
@testable import ProbeKit

/// Vision hands back the raw QR bit stream, not the payload. Getting this wrong
/// yields a 100% "decode rate" and garbage bytes — the exact symptom seen
/// during the step 0 spike.
final class QRBitstreamTests: XCTestCase {
    /// Build what Vision returns: 4-bit byte-mode indicator, then a
    /// `countBits`-wide length, then the payload, MSB-first.
    private func wrap(_ payload: [UInt8], countBits: Int) -> Data {
        var bits: [UInt8] = []
        func push(_ value: Int, _ width: Int) {
            for i in stride(from: width - 1, through: 0, by: -1) {
                bits.append(UInt8((value >> i) & 1))
            }
        }
        push(0b0100, 4)
        push(payload.count, countBits)
        for b in payload { push(Int(b), 8) }
        while bits.count % 8 != 0 { bits.append(0) }

        var out = [UInt8]()
        for i in stride(from: 0, to: bits.count, by: 8) {
            var byte: UInt8 = 0
            for j in 0..<8 { byte = (byte << 1) | bits[i + j] }
            out.append(byte)
        }
        return Data(out)
    }

    func testUnwrapsVersion40StyleSixteenBitLength() {
        let payload = (0..<600).map { UInt8($0 % 256) }
        let got = QRBitstream.bytePayload(from: wrap(payload, countBits: 16))
        XCTAssertEqual(got.map([UInt8].init), payload)
    }

    func testUnwrapsSmallSymbolEightBitLength() {
        let payload: [UInt8] = Array("QRSP hello".utf8)
        let got = QRBitstream.bytePayload(from: wrap(payload, countBits: 8))
        XCTAssertEqual(got.map([UInt8].init), payload)
    }

    /// Arbitrary bytes are the whole point — a telemetry frame is protobuf, not
    /// text, so anything that round-trips only printable ASCII is useless here.
    func testHandlesArbitraryBinaryIncludingNulAndHighBytes() {
        let payload: [UInt8] = [0x00, 0xFF, 0x0A, 0x80, 0x7F, 0x00, 0x00, 0xAB]
        let got = QRBitstream.bytePayload(from: wrap(payload, countBits: 16))
        XCTAssertEqual(got.map([UInt8].init), payload)
    }

    func testRoundTripsARealEncodedFrame() throws {
        let frame = Fixtures.frame(Fixtures.typing(events: 40))
        let encoded = try FrameCodec.encode(frame)
        let unwrapped = QRBitstream.bytePayload(from: wrap([UInt8](encoded), countBits: 16))
        XCTAssertNotNil(unwrapped)
        XCTAssertEqual(try FrameCodec.decode(unwrapped!).events, frame.events)
    }

    func testRejectsNonByteMode() {
        // 0b0001 is numeric mode — not something we ever emit, and silently
        // misreading it would hand back plausible garbage.
        XCTAssertNil(QRBitstream.bytePayload(from: Data([0b0001_0000, 0x00, 0x00])))
    }

    func testRejectsEmptyAndTruncatedInput() {
        XCTAssertNil(QRBitstream.bytePayload(from: Data()))
        XCTAssertNil(QRBitstream.bytePayload(from: Data([0x40])))
    }
}
