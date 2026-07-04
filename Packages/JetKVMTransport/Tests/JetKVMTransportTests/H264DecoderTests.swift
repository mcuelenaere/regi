import XCTest
@testable import JetKVMTransport

final class H264DecoderTests: XCTestCase {
    func testNalUnitsSplitsAnnexB() {
        // 4-byte start, 3-byte start, 4-byte start.
        let data: [UInt8] = [
            0, 0, 0, 1, 0x67, 0xAA, 0xBB,   // SPS (type 7)
            0, 0, 1, 0x68, 0xCC,            // PPS (type 8)
            0, 0, 0, 1, 0x65, 0x01, 0x02,   // IDR slice (type 5)
        ]
        let nals = H264Decoder.nalUnits(in: data)
        XCTAssertEqual(nals.count, 3)
        XCTAssertEqual(nals[0].first! & 0x1F, 7)
        XCTAssertEqual(nals[1].first! & 0x1F, 8)
        XCTAssertEqual(nals[2].first! & 0x1F, 5)
        XCTAssertEqual(Array(nals[0]), [0x67, 0xAA, 0xBB])
        XCTAssertEqual(Array(nals[2]), [0x65, 0x01, 0x02])
    }

    func testNalUnitsEmptyAndNoStartCode() {
        XCTAssertTrue(H264Decoder.nalUnits(in: []).isEmpty)
        XCTAssertTrue(H264Decoder.nalUnits(in: [0x01, 0x02, 0x03]).isEmpty) // no start code
    }

    /// Wire parse + graceful handling: a rect whose payload has a VCL slice but
    /// no SPS/PPS can't build a session; it must return cleanly (framebuffer
    /// untouched), not throw or crash.
    func testDecodeWithoutParameterSetsIsNoOp() async throws {
        let fb = VNCFramebuffer(width: 4, height: 4)
        let payload: [UInt8] = [0, 0, 0, 1, 0x65, 0x11, 0x22] // IDR slice only
        var s = VNCByteWriter()
        s.writeU32(UInt32(payload.count)) // length
        s.writeU32(0)                     // flags
        s.writeBytes(payload)
        try await H264Decoder().decodeRect(
            RFBProtocol.RectHeader(x: 0, y: 0, width: 4, height: 4, encoding: RFBProtocol.Encoding.h264),
            channel: ScriptedByteChannel(s.data), framebuffer: fb)
        // Framebuffer stays at its initial opaque black.
        XCTAssertEqual(fb.pixelBGR(x: 0, y: 0).map { [$0.0, $0.1, $0.2] }, [0, 0, 0])
    }

    /// A reset-all flag with a zero-length payload must be handled without
    /// reading a body or crashing.
    func testResetFlagWithEmptyPayload() async throws {
        let fb = VNCFramebuffer(width: 2, height: 2)
        var s = VNCByteWriter()
        s.writeU32(0)   // length
        s.writeU32(0x2) // resetAllContexts
        try await H264Decoder().decodeRect(
            RFBProtocol.RectHeader(x: 0, y: 0, width: 2, height: 2, encoding: RFBProtocol.Encoding.h264),
            channel: ScriptedByteChannel(s.data), framebuffer: fb)
    }
}
