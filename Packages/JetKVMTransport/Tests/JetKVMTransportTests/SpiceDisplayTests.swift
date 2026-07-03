import XCTest
@testable import JetKVMTransport

final class SpiceDisplayTests: XCTestCase {

    // MARK: - Message parsing

    func testSurfaceCreateParse() throws {
        var w = SpiceByteWriter()
        w.writeU32(0)      // surface_id
        w.writeU32(1024)   // width
        w.writeU32(768)    // height
        w.writeU32(32)     // format = 32_xRGB
        w.writeU32(1)      // flags = PRIMARY
        let s = try SpiceMsgSurfaceCreate.parse(w.data)
        XCTAssertEqual(s.surfaceID, 0)
        XCTAssertEqual(s.width, 1024)
        XCTAssertEqual(s.height, 768)
        XCTAssertTrue(s.isPrimary)
    }

    func testRectDimensions() {
        let r = SpiceRect(top: 10, left: 20, bottom: 60, right: 120)
        XCTAssertEqual(r.width, 100)
        XCTAssertEqual(r.height, 50)
    }

    /// Full DRAW_COPY path: base + clip, pointer-offset to an embedded BITMAP
    /// image, descriptor + BitmapData parse, decode, and blit to a surface.
    func testDrawCopyWithBitmapImageEndToEnd() throws {
        let W = 2, H = 2
        // 2×2 BGRX source (top-down), stride 8.
        let bmp: [UInt8] = [
            10, 20, 30, 0,   40, 50, 60, 0,      // row 0
            70, 80, 90, 0,   100, 110, 120, 0,   // row 1
        ]

        var p = SpiceByteWriter()
        // DisplayBase: surface_id + box + clip(NONE) = 21 bytes.
        p.writeU32(0)
        writeRect(&p, top: 0, left: 0, bottom: Int32(H), right: Int32(W))
        p.writeU8(0)                       // clip type NONE
        // Copy fixed part = 36 bytes; image follows at offset 21 + 36 = 57.
        let imageOffset: UInt32 = 57
        p.writeU32(imageOffset)            // src_bitmap pointer
        writeRect(&p, top: 0, left: 0, bottom: Int32(H), right: Int32(W))  // src_area
        p.writeU16(0)                      // rop
        p.writeU8(0)                       // scale
        p.writeU8(0); p.writeI32(0); p.writeI32(0); p.writeU32(0)  // QMask
        XCTAssertEqual(p.count, Int(imageOffset), "header size must match declared offset")
        // Image: descriptor(18) + BitmapData.
        p.writeU64(0)                      // id
        p.writeU8(SpiceMsg.ImageType.bitmap.rawValue)
        p.writeU8(0)                       // image flags
        p.writeU32(UInt32(W)); p.writeU32(UInt32(H))   // descriptor w/h
        p.writeU8(8)                       // bitmap_fmt = 32BIT
        p.writeU8(0x04)                    // TOP_DOWN
        p.writeU32(UInt32(W)); p.writeU32(UInt32(H))   // x, y
        p.writeU32(UInt32(W * 4))          // stride
        p.writeU32(0)                      // palette ptr (none)
        p.writeBytes(bmp)

        let copy = try SpiceDrawCopy.parse(p.data)
        XCTAssertEqual(copy.base.surfaceID, 0)
        XCTAssertEqual(copy.base.box, SpiceRect(top: 0, left: 0, bottom: 2, right: 2))
        let image = try XCTUnwrap(copy.image, "src_bitmap should resolve")
        XCTAssertEqual(image.type, .bitmap)

        let decoder = SpiceImageDecoder()
        let decoded = try XCTUnwrap(decoder.decode(image))
        XCTAssertEqual(decoded.width, 2)
        XCTAssertEqual(decoded.height, 2)

        let surface = SpiceSurface(width: 2, height: 2)
        surface.blit(src: decoded.pixels, srcWidth: 2, srcHeight: 2,
                     srcArea: copy.srcArea, dest: copy.base.box)
        // Pixel (0,0) = B,G,R,A.
        XCTAssertEqual(Array(surface.pixels.prefix(4)), [10, 20, 30, 0xFF])
        // Pixel (1,1) = last 4 bytes.
        XCTAssertEqual(Array(surface.pixels.suffix(4)), [100, 110, 120, 0xFF])
    }

    func testDrawFillParseAndFill() throws {
        var p = SpiceByteWriter()
        p.writeU32(0)
        writeRect(&p, top: 0, left: 0, bottom: 2, right: 2)
        p.writeU8(0)                    // clip NONE
        p.writeU8(1)                    // brush SOLID
        p.writeU32(0x00112233)          // color RRGGBB

        let fill = try SpiceDrawFill.parse(p.data)
        XCTAssertEqual(fill.solidColor, 0x00112233)

        let surface = SpiceSurface(width: 2, height: 2)
        surface.fill(rect: fill.base.box, color: fill.solidColor!)
        // 0x112233 → R=0x11 G=0x22 B=0x33 → BGRA
        XCTAssertEqual(Array(surface.pixels.prefix(4)), [0x33, 0x22, 0x11, 0xFF])
    }

    func testSurfaceBlitClampsOutOfBounds() {
        // Source larger than the surface; blit must clamp, not crash.
        let src = [UInt8](repeating: 0x77, count: 4 * 4 * 4)   // 4×4 BGRA
        let surface = SpiceSurface(width: 2, height: 2)
        surface.blit(src: src, srcWidth: 4, srcHeight: 4,
                     srcArea: SpiceRect(top: 0, left: 0, bottom: 4, right: 4),
                     dest: SpiceRect(top: 0, left: 0, bottom: 4, right: 4))
        XCTAssertEqual(surface.pixels.count, 2 * 2 * 4)
        XCTAssertEqual(surface.pixels.allSatisfy { $0 == 0x77 }, true)
    }

    // MARK: - Video streams

    func testStreamCreateParse() throws {
        var w = SpiceByteWriter()
        w.writeU32(0)                 // surface_id
        w.writeU32(7)                 // id
        w.writeU8(0)                  // flags
        w.writeU8(1)                  // codec_type = MJPEG
        w.writeU64(0)                 // stamp
        w.writeU32(640); w.writeU32(480)   // stream w/h
        w.writeU32(640); w.writeU32(480)   // src w/h
        writeRect(&w, top: 10, left: 20, bottom: 490, right: 660)   // dest
        let s = try SpiceMsgStreamCreate.parse(w.data)
        XCTAssertEqual(s.streamID, 7)
        XCTAssertEqual(s.codec, .mjpeg)
        XCTAssertEqual(s.dest, SpiceRect(top: 10, left: 20, bottom: 490, right: 660))
    }

    func testStreamDataParse() throws {
        var w = SpiceByteWriter()
        w.writeU32(7)                 // id
        w.writeU32(12345)             // multi_media_time
        w.writeU32(4)                 // data_size
        w.writeBytes([0xDE, 0xAD, 0xBE, 0xEF])
        let d = try SpiceMsgStreamData.parse(w.data)
        XCTAssertEqual(d.streamID, 7)
        XCTAssertEqual(d.data, [0xDE, 0xAD, 0xBE, 0xEF])
    }

    // MARK: - Channel

    func testDisplayChannelCompositesFillOnPrimary() async throws {
        // Connection is never started; we drive handle() directly.
        let conn = SpiceChannelConnection(host: "unused", port: 1, useTLS: false,
                                          allowSelfSigned: false, channelType: .display, channelID: 0)
        let channel = SpiceDisplayChannel(connection: conn)
        let box = FrameBox()
        channel.onFrame = { box.set($0) }

        var sc = SpiceByteWriter()
        sc.writeU32(0); sc.writeU32(2); sc.writeU32(2); sc.writeU32(32); sc.writeU32(1)  // primary 2×2
        await channel.handle(type: SpiceMsg.Display.surfaceCreate.rawValue, payload: sc.data)

        var f = SpiceByteWriter()
        f.writeU32(0)
        writeRect(&f, top: 0, left: 0, bottom: 2, right: 2)
        f.writeU8(0)                 // clip NONE
        f.writeU8(1)                 // brush SOLID
        f.writeU32(0x00112233)
        await channel.handle(type: SpiceMsg.Display.drawFill.rawValue, payload: f.data)

        // Emission is coalesced onto a timer; drive it directly here.
        channel.emitIfDirty()
        let frame = try XCTUnwrap(box.get(), "primary surface should emit a frame")
        XCTAssertEqual(frame.width, 2)
        XCTAssertEqual(frame.height, 2)
        XCTAssertEqual(Array(frame.bgra.prefix(4)), [0x33, 0x22, 0x11, 0xFF])
    }

    func testFromCacheReusesDecodedImage() {
        let decoder = SpiceImageDecoder()
        // A cacheable 1×1 bitmap (CACHE_ME) with id 42.
        let cached = SpiceImage(type: .bitmap, id: 42, cacheMe: true, width: 1, height: 1,
                                payload: [11, 22, 33, 0],
                                bitmap: .init(format: 8, flags: 0x04, stride: 4))
        let first = decoder.decode(cached)
        XCTAssertEqual(first?.pixels, [11, 22, 33, 0xFF])
        // FROM_CACHE referencing id 42 must return the same pixels.
        let ref = SpiceImage(type: .fromCache, id: 42, cacheMe: false, width: 1, height: 1,
                             payload: [], bitmap: nil)
        XCTAssertEqual(decoder.decode(ref)?.pixels, [11, 22, 33, 0xFF])
    }

    private func writeRect(_ w: inout SpiceByteWriter, top: Int32, left: Int32, bottom: Int32, right: Int32) {
        w.writeI32(top); w.writeI32(left); w.writeI32(bottom); w.writeI32(right)
    }
}

/// Thread-safe holder so the @Sendable onFrame closure can record a frame.
private final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: SpiceFrame?
    func set(_ v: SpiceFrame) { lock.lock(); frame = v; lock.unlock() }
    func get() -> SpiceFrame? { lock.lock(); defer { lock.unlock() }; return frame }
}
