import Foundation
import CoreGraphics
import ImageIO
import CSpiceCodecs

/// Decodes a parsed `SpiceImage` into a top-down BGRA8888 pixel buffer,
/// dispatching by type to the vendored C codecs (QUIC/LZ/GLZ), ImageIO
/// (JPEG), or a raw conversion (BITMAP). Holds the GLZ decoder window, which
/// must persist across the display channel's lifetime (GLZ images
/// back-reference earlier ones), so this is per-channel and not thread-safe.
final class SpiceImageDecoder {
    struct Decoded { var pixels: [UInt8]; var width: Int; var height: Int }

    private let glzWindow: OpaquePointer?

    // Client-side image cache (SPICE CACHE_ME / FROM_CACHE). Bounded FIFO.
    private var cache: [UInt64: Decoded] = [:]
    private var cacheOrder: [UInt64] = []
    private let cacheLimit = 1024

    init() { glzWindow = regi_glz_window_new() }
    deinit { regi_glz_window_free(glzWindow) }

    func reset() {
        regi_glz_window_reset(glzWindow)
        cache.removeAll()
        cacheOrder.removeAll()
    }

    func decode(_ image: SpiceImage) -> Decoded? {
        if image.type == .fromCache {
            return cache[image.id]
        }
        let decoded: Decoded?
        switch image.type {
        case .quic:
            decoded = decodeC(image.payload) { data, len, out, w, h in
                regi_quic_decode_bgra(data, len, out, w, h)
            }
        case .lzRgb:
            decoded = decodeLZorGLZ(image.payload, glz: false)
        case .glzRgb:
            decoded = decodeLZorGLZ(image.payload, glz: true)
        case .jpeg:
            decoded = decodeJPEG(image.payload)
        case .bitmap:
            decoded = decodeBitmap(image)
        default:
            decoded = nil
        }
        if let decoded, image.cacheMe {
            store(id: image.id, decoded)
        }
        return decoded
    }

    private func store(id: UInt64, _ decoded: Decoded) {
        if cache[id] == nil {
            cacheOrder.append(id)
            if cacheOrder.count > cacheLimit {
                let evict = cacheOrder.removeFirst()
                cache[evict] = nil
            }
        }
        cache[id] = decoded
    }

    // MARK: - Codec bridges

    private func decodeC(_ payload: [UInt8],
                         _ call: (UnsafePointer<UInt8>?, Int,
                                  UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
                                  UnsafeMutablePointer<UInt32>,
                                  UnsafeMutablePointer<UInt32>) -> Int32) -> Decoded? {
        payload.withUnsafeBufferPointer { buf -> Decoded? in
            var out: UnsafeMutablePointer<UInt8>? = nil
            var w: UInt32 = 0, h: UInt32 = 0
            guard call(buf.baseAddress, buf.count, &out, &w, &h) == 0, let out else { return nil }
            defer { regi_free(out) }
            let pixels = Array(UnsafeBufferPointer(start: out, count: Int(w) * Int(h) * 4))
            return Decoded(pixels: pixels, width: Int(w), height: Int(h))
        }
    }

    private func decodeLZorGLZ(_ payload: [UInt8], glz: Bool) -> Decoded? {
        payload.withUnsafeBufferPointer { buf -> Decoded? in
            var out: UnsafeMutablePointer<UInt8>? = nil
            var w: UInt32 = 0, h: UInt32 = 0, topDown: Int32 = 0
            let rc = glz
                ? regi_glz_decode_bgra(glzWindow, buf.baseAddress, buf.count, nil, &out, &w, &h, &topDown)
                : regi_lz_decode_bgra(buf.baseAddress, buf.count, nil, &out, &w, &h, &topDown)
            guard rc == 0, let out else { return nil }
            defer { regi_free(out) }
            var pixels = Array(UnsafeBufferPointer(start: out, count: Int(w) * Int(h) * 4))
            if topDown == 0 { Self.flipRows(&pixels, width: Int(w), height: Int(h)) }
            return Decoded(pixels: pixels, width: Int(w), height: Int(h))
        }
    }

    private func decodeJPEG(_ payload: [UInt8]) -> Decoded? {
        guard let source = CGImageSourceCreateWithData(Data(payload) as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue     // → BGRA
        guard let ctx = pixels.withUnsafeMutableBytes({ raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: bitmapInfo)
        }) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Decoded(pixels: pixels, width: w, height: h)
    }

    // MARK: - Raw bitmap

    private func decodeBitmap(_ image: SpiceImage) -> Decoded? {
        guard let info = image.bitmap else { return nil }
        let w = Int(image.width), h = Int(image.height)
        guard w > 0, h > 0 else { return nil }
        let stride = Int(info.stride)
        let src = image.payload
        guard src.count >= stride * h else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 4)

        // bitmap_fmt: 6=16BIT(555), 7=24BIT(bgr), 8=32BIT(xRGB), 9=RGBA(argb).
        out.withUnsafeMutableBufferPointer { d in
            src.withUnsafeBufferPointer { s in
                for y in 0..<h {
                    let srcRow = (info.topDown ? y : (h - 1 - y)) * stride
                    var di = y * w * 4
                    switch info.format {
                    case 8, 9:   // 32-bit: already B,G,R,(x|a) little-endian
                        for x in 0..<w {
                            let si = srcRow + x * 4
                            d[di] = s[si]; d[di + 1] = s[si + 1]; d[di + 2] = s[si + 2]
                            d[di + 3] = info.format == 9 ? s[si + 3] : 0xFF
                            di += 4
                        }
                    case 7:      // 24-bit b,g,r
                        for x in 0..<w {
                            let si = srcRow + x * 3
                            d[di] = s[si]; d[di + 1] = s[si + 1]; d[di + 2] = s[si + 2]; d[di + 3] = 0xFF
                            di += 4
                        }
                    case 6:      // 16-bit 555
                        for x in 0..<w {
                            let si = srcRow + x * 2
                            let v = UInt16(s[si]) | (UInt16(s[si + 1]) << 8)
                            let r5 = (v >> 10) & 0x1F, g5 = (v >> 5) & 0x1F, b5 = v & 0x1F
                            d[di] = UInt8(b5 << 3); d[di + 1] = UInt8(g5 << 3)
                            d[di + 2] = UInt8(r5 << 3); d[di + 3] = 0xFF
                            di += 4
                        }
                    default:
                        break
                    }
                }
            }
        }
        return Decoded(pixels: out, width: w, height: h)
    }

    private static func flipRows(_ pixels: inout [UInt8], width: Int, height: Int) {
        let rowBytes = width * 4
        guard rowBytes > 0, height > 1, pixels.count >= rowBytes * height else { return }
        var top = 0, bottom = height - 1
        while top < bottom {
            for i in 0..<rowBytes {
                pixels.swapAt(top * rowBytes + i, bottom * rowBytes + i)
            }
            top += 1; bottom -= 1
        }
    }
}
