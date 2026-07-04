import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import zlib
@testable import VNCKit

/// A live zlib deflate stream that flushes each chunk with Z_SYNC_FLUSH, so the
/// emitted segments carry dictionary state across calls — mirroring how a Tight
/// server drives one persistent stream across rectangles.
private final class PersistentDeflater {
    private var stream = z_stream()
    init() {
        _ = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15, 8,
                          Z_DEFAULT_STRATEGY, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
    }
    deinit { deflateEnd(&stream) }

    func flush(_ input: [UInt8]) -> [UInt8] {
        var inp = input
        var out = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 8192)
        inp.withUnsafeMutableBytes { rawIn in
            stream.next_in = rawIn.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = UInt32(rawIn.count)
            repeat {
                let produced = chunk.withUnsafeMutableBytes { rawOut -> Int in
                    stream.next_out = rawOut.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = UInt32(rawOut.count)
                    _ = zlib.deflate(&stream, Z_SYNC_FLUSH)
                    return rawOut.count - Int(stream.avail_out)
                }
                out.append(contentsOf: chunk.prefix(produced))
            } while stream.avail_out == 0
        }
        stream.next_in = nil
        stream.next_out = nil
        return out
    }
}

final class TightDecoderTests: XCTestCase {
    private func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> RFBProtocol.RectHeader {
        RFBProtocol.RectHeader(x: x, y: y, width: w, height: h, encoding: RFBProtocol.Encoding.tight)
    }

    private func decode(_ script: [UInt8], into fb: VNCFramebuffer,
                        rect r: RFBProtocol.RectHeader,
                        decoder: TightDecoder = TightDecoder(pixelFormat: .bgra32)) async throws -> Bool {
        let channel = ScriptedByteChannel(Data(script))
        return try await decoder.decodeRect(r, channel: channel, framebuffer: fb)
    }

    // MARK: - Fill

    func testFill() async throws {
        let fb = VNCFramebuffer(width: 4, height: 4)
        // control 0x80 (fill) + TPIXEL R,G,B = 10,20,30
        let jpeg = try await decode([0x80, 10, 20, 30], into: fb, rect: rect(0, 0, 4, 4))
        XCTAssertFalse(jpeg)
        XCTAssertEqual(fb.pixelBGR(x: 0, y: 0).map { [$0.0, $0.1, $0.2] }, [30, 20, 10]) // BGR
        XCTAssertEqual(fb.pixelBGR(x: 3, y: 3).map { [$0.0, $0.1, $0.2] }, [30, 20, 10])
    }

    // MARK: - Basic copy filter

    func testCopyFilterUncompressed() async throws {
        // 2x1 rect → size = 6 < 12 → raw RGB, no zlib.
        let fb = VNCFramebuffer(width: 2, height: 1)
        // control 0x00 (basic, stream 0, no explicit filter → copy)
        let script: [UInt8] = [0x00, /*px0 RGB*/ 1, 2, 3, /*px1 RGB*/ 4, 5, 6]
        _ = try await decode(script, into: fb, rect: rect(0, 0, 2, 1))
        XCTAssertEqual(fb.pixelBGR(x: 0, y: 0).map { [$0.0, $0.1, $0.2] }, [3, 2, 1])
        XCTAssertEqual(fb.pixelBGR(x: 1, y: 0).map { [$0.0, $0.1, $0.2] }, [6, 5, 4])
    }

    func testCopyFilterZlib() async throws {
        // 2x2 rect → size = 12 → zlib path.
        let fb = VNCFramebuffer(width: 2, height: 2)
        var rgb = [UInt8]()
        for i in 0..<4 { rgb += [UInt8(i * 10), UInt8(i * 10 + 1), UInt8(i * 10 + 2)] }
        let deflater = PersistentDeflater()
        let compressed = deflater.flush(rgb)
        var script: [UInt8] = [0x00]
        script += compactLength(compressed.count)
        script += compressed
        _ = try await decode(script, into: fb, rect: rect(0, 0, 2, 2))
        XCTAssertEqual(fb.pixelBGR(x: 0, y: 0).map { [$0.0, $0.1, $0.2] }, [2, 1, 0])
        XCTAssertEqual(fb.pixelBGR(x: 1, y: 1).map { [$0.0, $0.1, $0.2] }, [32, 31, 30])
    }

    // MARK: - Palette filter

    func testPaletteFilterMultiColorZlib() async throws {
        // 4x4, 3 colours → rowBytes = 4, size = 16 (zlib).
        let fb = VNCFramebuffer(width: 4, height: 4)
        let palette: [UInt8] = [0, 0, 0,   /*0 black*/
                                255, 0, 0, /*1 R=255*/
                                0, 255, 0] /*2 G=255*/
        var indices = [UInt8](repeating: 0, count: 16)
        indices[0] = 1  // (0,0) → red
        indices[5] = 2  // (1,1) → green
        let deflater = PersistentDeflater()
        let compressed = deflater.flush(indices)
        // control 0x40 (basic, stream 0, explicit filter) + filterID 1 (palette)
        // + numColors-1 (2) + palette(9 bytes) + compactLength + compressed.
        var script: [UInt8] = [0x40, 0x01, 0x02]
        script += palette
        script += compactLength(compressed.count)
        script += compressed
        _ = try await decode(script, into: fb, rect: rect(0, 0, 4, 4))
        XCTAssertEqual(fb.pixelBGR(x: 0, y: 0).map { [$0.0, $0.1, $0.2] }, [0, 0, 255]) // red
        XCTAssertEqual(fb.pixelBGR(x: 1, y: 1).map { [$0.0, $0.1, $0.2] }, [0, 255, 0]) // green
        XCTAssertEqual(fb.pixelBGR(x: 3, y: 3).map { [$0.0, $0.1, $0.2] }, [0, 0, 0])   // black
    }

    func testPaletteFilterTwoColorBitPacked() async throws {
        // 8x1, 2 colours → rowBytes = 1 (bit-packed), size = 1 < 12 → raw.
        let fb = VNCFramebuffer(width: 8, height: 1)
        let palette: [UInt8] = [0, 0, 0, 255, 255, 255] // 0=black, 1=white
        // bits MSB→LSB across the row: 1,0,1,0,0,0,0,1 = 0b10100001 = 0xA1
        let script: [UInt8] = [0x40, 0x01, 0x01] + palette + [0xA1]
        _ = try await decode(script, into: fb, rect: rect(0, 0, 8, 1))
        XCTAssertEqual(fb.pixelBGR(x: 0, y: 0)?.0, 255) // white
        XCTAssertEqual(fb.pixelBGR(x: 1, y: 0)?.0, 0)   // black
        XCTAssertEqual(fb.pixelBGR(x: 2, y: 0)?.0, 255) // white
        XCTAssertEqual(fb.pixelBGR(x: 7, y: 0)?.0, 255) // white
    }

    // MARK: - Gradient filter

    func testGradientFilterUncompressed() async throws {
        // 2x1 → size = 6 < 12 → raw deltas. Prediction P = left+above-aboveLeft.
        // x=0: P=0 → value = delta. x=1: P=clamp(left) → value = (delta+left)&0xFF.
        let fb = VNCFramebuffer(width: 2, height: 1)
        // deltas: px0 = (50,60,70); px1 = (5,5,5) → px1 value = (55,65,75)
        let script: [UInt8] = [0x40, 0x02, 50, 60, 70, 5, 5, 5]
        _ = try await decode(script, into: fb, rect: rect(0, 0, 2, 1))
        XCTAssertEqual(fb.pixelBGR(x: 0, y: 0).map { [$0.0, $0.1, $0.2] }, [70, 60, 50])
        XCTAssertEqual(fb.pixelBGR(x: 1, y: 0).map { [$0.0, $0.1, $0.2] }, [75, 65, 55])
    }

    // MARK: - JPEG

    func testJPEG() async throws {
        let w = 16, h = 16
        let jpegData = makeJPEG(width: w, height: h, r: 200, g: 100, b: 50)
        XCTAssertFalse(jpegData.isEmpty)
        let fb = VNCFramebuffer(width: w, height: h)
        var script: [UInt8] = [0x90] // JPEG
        script += compactLength(jpegData.count)
        script += [UInt8](jpegData)
        let usedJPEG = try await decode(script, into: fb, rect: rect(0, 0, w, h))
        XCTAssertTrue(usedJPEG)
        // Lossy — allow tolerance around the solid fill.
        let (b, g, r) = fb.pixelBGR(x: 8, y: 8)!
        XCTAssertEqual(Int(r), 200, accuracy: 12)
        XCTAssertEqual(Int(g), 100, accuracy: 12)
        XCTAssertEqual(Int(b), 50, accuracy: 12)
    }

    // MARK: - Compact length

    func testCompactLength() async throws {
        let d = TightDecoder(pixelFormat: .bgra32)
        // 1-byte: 0x7F = 127
        var ch = ScriptedByteChannel(Data([0x7F]))
        var n = try await d.readCompactLength(ch)
        XCTAssertEqual(n, 127)
        // 2-byte: 0x80|0x01, 0x02 → 1 | (2<<7) = 257
        ch = ScriptedByteChannel(Data([0x81, 0x02]))
        n = try await d.readCompactLength(ch)
        XCTAssertEqual(n, 1 | (2 << 7))
        // 3-byte: 0x80, 0x80, 0x04 → 0 | 0 | (4<<14)
        ch = ScriptedByteChannel(Data([0x80, 0x80, 0x04]))
        n = try await d.readCompactLength(ch)
        XCTAssertEqual(n, 4 << 14)
    }

    // MARK: - Zlib persistence & reset

    func testZlibPersistenceAcrossRects() async throws {
        // Two 2x2 copy rects through one decoder (stream 0). The second segment
        // back-references the first's dictionary, so only a persistent stream
        // decodes it correctly.
        let decoder = TightDecoder(pixelFormat: .bgra32)
        let deflater = PersistentDeflater()
        let rgb1 = (0..<12).map { UInt8($0) }
        let rgb2 = (12..<24).map { UInt8($0) }
        let c1 = deflater.flush(rgb1)
        let c2 = deflater.flush(rgb2)

        let fb1 = VNCFramebuffer(width: 2, height: 2)
        _ = try await decode([0x00] + compactLength(c1.count) + c1, into: fb1, rect: rect(0, 0, 2, 2), decoder: decoder)
        XCTAssertEqual(fb1.pixelBGR(x: 0, y: 0).map { [$0.0, $0.1, $0.2] }, [2, 1, 0])

        let fb2 = VNCFramebuffer(width: 2, height: 2)
        _ = try await decode([0x00] + compactLength(c2.count) + c2, into: fb2, rect: rect(0, 0, 2, 2), decoder: decoder)
        XCTAssertEqual(fb2.pixelBGR(x: 0, y: 0).map { [$0.0, $0.1, $0.2] }, [14, 13, 12])
    }

    func testResetBitStartsFreshStream() async throws {
        // Rect 1 primes stream 0. Rect 2 sets the reset bit for stream 0 and
        // carries an independent, complete deflate — which only decodes if the
        // stream was reset first.
        let decoder = TightDecoder(pixelFormat: .bgra32)
        let deflater = PersistentDeflater()
        let rgb1 = (0..<12).map { UInt8($0) }
        let c1 = deflater.flush(rgb1)
        let fb1 = VNCFramebuffer(width: 2, height: 2)
        _ = try await decode([0x00] + compactLength(c1.count) + c1, into: fb1, rect: rect(0, 0, 2, 2), decoder: decoder)

        // Fresh, independent stream for rect 2.
        let rgb2 = (100..<112).map { UInt8($0) }
        let freshCompressed = [UInt8](try ZlibCodec.deflate(Data(rgb2)))
        let fb2 = VNCFramebuffer(width: 2, height: 2)
        // control 0x01: basic, stream 0, reset stream-0 bit set.
        _ = try await decode([0x01] + compactLength(freshCompressed.count) + freshCompressed,
                             into: fb2, rect: rect(0, 0, 2, 2), decoder: decoder)
        XCTAssertEqual(fb2.pixelBGR(x: 0, y: 0).map { [$0.0, $0.1, $0.2] }, [102, 101, 100])
    }

    // MARK: - Helpers

    private func compactLength(_ n: Int) -> [UInt8] {
        var out = [UInt8]()
        var v = n
        out.append(UInt8(v & 0x7F) | (v >= 0x80 ? 0x80 : 0))
        v >>= 7
        if v > 0 {
            out.append(UInt8(v & 0x7F) | (v >= 0x80 ? 0x80 : 0))
            v >>= 7
            if v > 0 { out.append(UInt8(v & 0xFF)) }
        }
        return out
    }

    private func makeJPEG(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
