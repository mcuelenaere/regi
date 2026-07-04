import XCTest
@testable import JetKVMTransport

/// Tests for the fallback frame encodings: Zlib, Hextile, ZRLE.
final class VNCEncodingsTests: XCTestCase {
    private func rect(_ w: Int, _ h: Int) -> RFBProtocol.RectHeader {
        RFBProtocol.RectHeader(x: 0, y: 0, width: w, height: h, encoding: 0)
    }

    private func bgr(_ fb: VNCFramebuffer, _ x: Int, _ y: Int) -> [UInt8]? {
        fb.pixelBGR(x: x, y: y).map { [$0.0, $0.1, $0.2] }
    }

    // MARK: - Zlib

    func testZlibDecode() async throws {
        let fb = VNCFramebuffer(width: 2, height: 2)
        // Row-major BGRA (X byte ignored — blit forces opaque).
        let raw: [UInt8] = [1, 2, 3, 0,  4, 5, 6, 0,  7, 8, 9, 0,  10, 11, 12, 0]
        let compressed = [UInt8](try ZlibCodec.deflate(Data(raw)))
        var script = VNCByteWriter()
        script.writeU32(UInt32(compressed.count))
        script.writeBytes(compressed)
        let channel = ScriptedByteChannel(script.data)
        try await ZlibDecoder().decodeRect(rect(2, 2), channel: channel, framebuffer: fb)
        XCTAssertEqual(bgr(fb, 0, 0), [1, 2, 3])
        XCTAssertEqual(bgr(fb, 1, 0), [4, 5, 6])
        XCTAssertEqual(bgr(fb, 1, 1), [10, 11, 12])
    }

    // MARK: - Hextile

    func testHextileRawTile() async throws {
        let fb = VNCFramebuffer(width: 2, height: 2)
        var s = VNCByteWriter()
        s.writeU8(0x01) // Raw subencoding
        // 4 PIXELs, row-major, little-endian BGRA [B,G,R,X].
        s.writeBytes([1, 2, 3, 0,  4, 5, 6, 0,  7, 8, 9, 0,  10, 11, 12, 0])
        try await HextileDecoder().decodeRect(rect(2, 2), channel: ScriptedByteChannel(s.data), framebuffer: fb)
        XCTAssertEqual(bgr(fb, 0, 0), [1, 2, 3])
        XCTAssertEqual(bgr(fb, 1, 1), [10, 11, 12])
    }

    func testHextileBackgroundAndColouredSubrect() async throws {
        let fb = VNCFramebuffer(width: 4, height: 4)
        var s = VNCByteWriter()
        // bg(0x02) | anySubrects(0x08) | subrectsColoured(0x10)
        s.writeU8(0x02 | 0x08 | 0x10)
        s.writeBytes([100, 0, 0, 0])       // bg = (B,G,R) (100,0,0)
        s.writeU8(1)                        // one subrect
        s.writeBytes([0, 200, 0, 0])        // subrect colour (0,200,0)
        s.writeU8((1 << 4) | 1)             // x=1, y=1
        s.writeU8(((2 - 1) << 4) | (2 - 1)) // w=2, h=2
        try await HextileDecoder().decodeRect(rect(4, 4), channel: ScriptedByteChannel(s.data), framebuffer: fb)
        XCTAssertEqual(bgr(fb, 0, 0), [100, 0, 0])   // background
        XCTAssertEqual(bgr(fb, 1, 1), [0, 200, 0])   // subrect
        XCTAssertEqual(bgr(fb, 2, 2), [0, 200, 0])   // subrect
        XCTAssertEqual(bgr(fb, 3, 3), [100, 0, 0])   // background
    }

    // MARK: - ZRLE

    private func zrleScript(_ tileBytes: [UInt8]) throws -> Data {
        let compressed = [UInt8](try ZlibCodec.deflate(Data(tileBytes)))
        var s = VNCByteWriter()
        s.writeU32(UInt32(compressed.count))
        s.writeBytes(compressed)
        return s.data
    }

    func testZRLESolidTile() async throws {
        let fb = VNCFramebuffer(width: 2, height: 2)
        let script = try zrleScript([1, 50, 60, 70]) // solid, CPIXEL B,G,R
        try await ZRLEDecoder().decodeRect(rect(2, 2), channel: ScriptedByteChannel(script), framebuffer: fb)
        XCTAssertEqual(bgr(fb, 0, 0), [50, 60, 70])
        XCTAssertEqual(bgr(fb, 1, 1), [50, 60, 70])
    }

    func testZRLERawTile() async throws {
        let fb = VNCFramebuffer(width: 2, height: 1)
        let script = try zrleScript([0, /*px0*/ 2, 3, 4, /*px1*/ 5, 6, 7]) // raw CPIXELs
        try await ZRLEDecoder().decodeRect(rect(2, 1), channel: ScriptedByteChannel(script), framebuffer: fb)
        XCTAssertEqual(bgr(fb, 0, 0), [2, 3, 4])
        XCTAssertEqual(bgr(fb, 1, 0), [5, 6, 7])
    }

    func testZRLEPackedPalette() async throws {
        let fb = VNCFramebuffer(width: 8, height: 1)
        // paletteSize 2 → bpp 1. palette[0]=black, palette[1]=white.
        // Indices cols 0..7 = 1,0,1,0,0,0,0,1 → MSB-first byte 0b10100001 = 0xA1.
        let script = try zrleScript([2, 0, 0, 0, 255, 255, 255, 0xA1])
        try await ZRLEDecoder().decodeRect(rect(8, 1), channel: ScriptedByteChannel(script), framebuffer: fb)
        XCTAssertEqual(bgr(fb, 0, 0), [255, 255, 255])
        XCTAssertEqual(bgr(fb, 1, 0), [0, 0, 0])
        XCTAssertEqual(bgr(fb, 2, 0), [255, 255, 255])
        XCTAssertEqual(bgr(fb, 7, 0), [255, 255, 255])
    }

    func testZRLEPlainRLE() async throws {
        let fb = VNCFramebuffer(width: 4, height: 1)
        // run1: (10,10,10) length 3 (1+sum, sum=2 → byte 2); run2: (20,20,20) length 1 (byte 0).
        let script = try zrleScript([128, 10, 10, 10, 2, 20, 20, 20, 0])
        try await ZRLEDecoder().decodeRect(rect(4, 1), channel: ScriptedByteChannel(script), framebuffer: fb)
        XCTAssertEqual(bgr(fb, 0, 0), [10, 10, 10])
        XCTAssertEqual(bgr(fb, 2, 0), [10, 10, 10])
        XCTAssertEqual(bgr(fb, 3, 0), [20, 20, 20])
    }

    func testZRLEPaletteRLE() async throws {
        let fb = VNCFramebuffer(width: 4, height: 1)
        // subencoding 130 → paletteSize 2. palette[0]=(1,1,1), palette[1]=(2,2,2).
        // RLE run of palette[0] length 3 (0x80, byte 2), then single palette[1] (0x01).
        let script = try zrleScript([130, 1, 1, 1, 2, 2, 2, 0x80, 2, 0x01])
        try await ZRLEDecoder().decodeRect(rect(4, 1), channel: ScriptedByteChannel(script), framebuffer: fb)
        XCTAssertEqual(bgr(fb, 0, 0), [1, 1, 1])
        XCTAssertEqual(bgr(fb, 2, 0), [1, 1, 1])
        XCTAssertEqual(bgr(fb, 3, 0), [2, 2, 2])
    }

    func testHextileMultipleTilesAcrossBoundary() async throws {
        // 18x1 → two tiles horizontally (16 + 2). Each a raw tile.
        let fb = VNCFramebuffer(width: 18, height: 1)
        var s = VNCByteWriter()
        s.writeU8(0x01) // tile 0: raw, 16 px all (10,10,10)
        for _ in 0..<16 { s.writeBytes([10, 10, 10, 0]) }
        s.writeU8(0x01) // tile 1: raw, 2 px all (20,20,20)
        for _ in 0..<2 { s.writeBytes([20, 20, 20, 0]) }
        try await HextileDecoder().decodeRect(rect(18, 1), channel: ScriptedByteChannel(s.data), framebuffer: fb)
        XCTAssertEqual(bgr(fb, 15, 0), [10, 10, 10]) // last px of tile 0
        XCTAssertEqual(bgr(fb, 16, 0), [20, 20, 20]) // first px of tile 1
        XCTAssertEqual(bgr(fb, 17, 0), [20, 20, 20])
    }

    func testZRLEMultipleTilesAcrossBoundary() async throws {
        // 66x1 → two tiles horizontally (64 + 2). Both solid, different colours.
        let fb = VNCFramebuffer(width: 66, height: 1)
        let script = try zrleScript([1, 5, 5, 5,   // tile 0 solid (5,5,5)
                                     1, 9, 9, 9])  // tile 1 solid (9,9,9)
        try await ZRLEDecoder().decodeRect(rect(66, 1), channel: ScriptedByteChannel(script), framebuffer: fb)
        XCTAssertEqual(bgr(fb, 0, 0), [5, 5, 5])
        XCTAssertEqual(bgr(fb, 63, 0), [5, 5, 5])  // last px of tile 0
        XCTAssertEqual(bgr(fb, 64, 0), [9, 9, 9])  // first px of tile 1
        XCTAssertEqual(bgr(fb, 65, 0), [9, 9, 9])
    }

    // MARK: - Opaque-alpha regression (Raw/Zlib must not land transparent)

    func testZlibBlitForcesOpaqueAlpha() async throws {
        let fb = VNCFramebuffer(width: 1, height: 1)
        let raw: [UInt8] = [9, 9, 9, 0] // X byte 0
        let compressed = [UInt8](try ZlibCodec.deflate(Data(raw)))
        var s = VNCByteWriter(); s.writeU32(UInt32(compressed.count)); s.writeBytes(compressed)
        try await ZlibDecoder().decodeRect(rect(1, 1), channel: ScriptedByteChannel(s.data), framebuffer: fb)
        var out = [UInt8](repeating: 0, count: 4)
        fb.withPixelBytes { buf in for i in 0..<4 { out[i] = buf[i] } }
        XCTAssertEqual(out[3], 0xFF, "alpha must be forced opaque despite the server's 0 X byte")
    }
}
