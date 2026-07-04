import Foundation
import CoreGraphics
import ImageIO

/// Decoder for the Tight encoding (7), the workhorse for QEMU consoles. Holds
/// the four persistent zlib streams the encoding shares across rectangles, plus
/// the JPEG decode path (ImageIO). One instance per connection, used only from
/// the stream engine's decode task.
///
/// Only the compact 3-byte TPIXEL form is implemented — guaranteed by our
/// negotiated pixel format (32bpp, depth 24, all maxes 255).
final class TightDecoder {
    private let pixelFormat: RFBProtocol.PixelFormat
    private var zlibStreams: [ZlibInflateStream] = (0..<4).map { _ in ZlibInflateStream() }

    init(pixelFormat: RFBProtocol.PixelFormat) {
        self.pixelFormat = pixelFormat
    }

    /// Discard all zlib stream state (on disconnect).
    func reset() {
        for s in zlibStreams { s.reset() }
    }

    /// Decode one Tight rect from `channel` into `framebuffer`. Returns whether
    /// the rect used JPEG (for stats).
    @discardableResult
    func decodeRect(
        _ rect: RFBProtocol.RectHeader,
        channel: any VNCByteChannel,
        framebuffer fb: VNCFramebuffer
    ) async throws -> Bool {
        let control = try await readU8(channel)

        // Bits 0-3: reset the corresponding zlib streams before anything else
        // (applies regardless of the compression mode in the high nibble).
        for i in 0..<4 where control & (1 << i) != 0 {
            zlibStreams[i].reset()
        }

        switch control >> 4 {
        case 0x08: // FillCompression: one TPIXEL, whole rect
            let px = try await channel.readExactly(3)
            let b = px[px.startIndex + 2], g = px[px.startIndex + 1], r = px[px.startIndex]
            try fb.fill(x: rect.x, y: rect.y, w: rect.width, h: rect.height, b: b, g: g, r: r)
            return false

        case 0x09: // JpegCompression
            let length = try await readCompactLength(channel)
            let jpeg = try await channel.readExactly(length)
            guard let bgra = Self.decodeJPEG(jpeg, width: rect.width, height: rect.height) else {
                throw VNCConnectionError.protocolError("Tight: JPEG decode failed (\(length) bytes)")
            }
            try bgra.withUnsafeBytes {
                try fb.blitBGRA(x: rect.x, y: rect.y, w: rect.width, h: rect.height, src: $0)
            }
            return true

        case let mode where mode & 0x08 == 0: // BasicCompression
            try await decodeBasic(rect, control: control, channel: channel, into: fb)
            return false

        default:
            throw VNCConnectionError.protocolError("Tight: unsupported compression \(control >> 4)")
        }
    }

    // MARK: - Basic compression

    private func decodeBasic(
        _ rect: RFBProtocol.RectHeader,
        control: UInt8,
        channel: any VNCByteChannel,
        into fb: VNCFramebuffer
    ) async throws {
        let streamIndex = Int((control >> 4) & 0x03)
        let filterID: UInt8 = control & 0x40 != 0 ? try await readU8(channel) : 0

        switch filterID {
        case 0: // Copy filter: packed TPIXELs
            let size = rect.width * rect.height * 3
            let rgb = try await readCompressed(size, stream: streamIndex, channel: channel)
            try fb.blitTPixels(x: rect.x, y: rect.y, w: rect.width, h: rect.height, rgb: rgb)

        case 1: // Palette filter
            let numColors = Int(try await readU8(channel)) + 1
            let paletteData = try await channel.readExactly(numColors * 3)
            let palette = [UInt8](paletteData)
            let rowBytes = numColors <= 2 ? (rect.width + 7) / 8 : rect.width
            let size = rowBytes * rect.height
            let indices = try await readCompressed(size, stream: streamIndex, channel: channel)
            let rgb = Self.expandPalette(indices, palette: palette, numColors: numColors,
                                         width: rect.width, height: rect.height)
            try fb.blitTPixels(x: rect.x, y: rect.y, w: rect.width, h: rect.height, rgb: rgb)

        case 2: // Gradient filter: per-component prediction over TPIXELs
            let size = rect.width * rect.height * 3
            let deltas = try await readCompressed(size, stream: streamIndex, channel: channel)
            let rgb = Self.undoGradient(deltas, width: rect.width, height: rect.height)
            try fb.blitTPixels(x: rect.x, y: rect.y, w: rect.width, h: rect.height, rgb: rgb)

        default:
            throw VNCConnectionError.protocolError("Tight: unknown filter \(filterID)")
        }
    }

    /// Read `size` bytes of filtered pixel data: raw when the uncompressed size
    /// is under 12 bytes (Tight skips zlib there), else a compact length +
    /// zlib-continued data through stream `stream`.
    private func readCompressed(_ size: Int, stream: Int, channel: any VNCByteChannel) async throws -> [UInt8] {
        guard size > 0 else { return [] }
        if size < 12 {
            return [UInt8](try await channel.readExactly(size))
        }
        let compressedLength = try await readCompactLength(channel)
        let compressed = try await channel.readExactly(compressedLength)
        do {
            return try zlibStreams[stream].inflate(compressed, expectedCount: size)
        } catch {
            throw VNCConnectionError.protocolError("Tight: inflate failed (\(error))")
        }
    }

    /// Tight's 1-3 byte compact length: 7 bits per byte, LSB first, high bit =
    /// continuation (third byte uses all 8 bits).
    func readCompactLength(_ channel: any VNCByteChannel) async throws -> Int {
        let b0 = try await readU8(channel)
        var length = Int(b0 & 0x7F)
        guard b0 & 0x80 != 0 else { return length }
        let b1 = try await readU8(channel)
        length |= Int(b1 & 0x7F) << 7
        guard b1 & 0x80 != 0 else { return length }
        let b2 = try await readU8(channel)
        length |= Int(b2) << 14
        return length
    }

    private func readU8(_ channel: any VNCByteChannel) async throws -> UInt8 {
        let data = try await channel.readExactly(1)
        guard let byte = data.first else {
            throw VNCConnectionError.protocolError("Tight: empty read")
        }
        return byte
    }

    // MARK: - Filters

    /// Expand palette indices to packed RGB. Two-colour palettes pack rows as
    /// bits (MSB = leftmost pixel, rows padded to a byte); larger ones use one
    /// index byte per pixel.
    static func expandPalette(_ indices: [UInt8], palette: [UInt8], numColors: Int,
                              width: Int, height: Int) -> [UInt8] {
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        let maxIndex = max(0, min(numColors, palette.count / 3) - 1)
        if numColors <= 2 {
            let rowBytes = (width + 7) / 8
            for y in 0..<height {
                for x in 0..<width {
                    let byteIndex = y * rowBytes + (x >> 3)
                    guard byteIndex < indices.count else { continue }
                    let bit = (indices[byteIndex] >> (7 - UInt8(x & 7))) & 1
                    let p = min(Int(bit), maxIndex) * 3
                    let o = (y * width + x) * 3
                    rgb[o] = palette[p]; rgb[o + 1] = palette[p + 1]; rgb[o + 2] = palette[p + 2]
                }
            }
        } else {
            for i in 0..<(width * height) where i < indices.count {
                let p = min(Int(indices[i]), maxIndex) * 3
                let o = i * 3
                rgb[o] = palette[p]; rgb[o + 1] = palette[p + 1]; rgb[o + 2] = palette[p + 2]
            }
        }
        return rgb
    }

    /// Undo the gradient filter: each wire byte is the difference from a
    /// prediction P = left + above − above-left (clamped per component).
    static func undoGradient(_ deltas: [UInt8], width: Int, height: Int) -> [UInt8] {
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        var prevRow = [Int](repeating: 0, count: width * 3)
        var thisRow = [Int](repeating: 0, count: width * 3)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<3 {
                    let left = x > 0 ? thisRow[(x - 1) * 3 + c] : 0
                    let above = prevRow[x * 3 + c]
                    let aboveLeft = x > 0 ? prevRow[(x - 1) * 3 + c] : 0
                    let prediction = min(255, max(0, left + above - aboveLeft))
                    let value = (Int(deltas[(y * width + x) * 3 + c]) + prediction) & 0xFF
                    thisRow[x * 3 + c] = value
                    rgb[(y * width + x) * 3 + c] = UInt8(value)
                }
            }
            swap(&prevRow, &thisRow)
        }
        return rgb
    }

    // MARK: - JPEG

    /// Decode a JPEG to tightly-packed BGRA at the rect's exact size. ImageIO +
    /// CGContext gives hardware-tuned decode without a new dependency; drawing
    /// into a fixed-size context also normalizes any size mismatch defensively.
    static func decodeJPEG(_ data: Data, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue // → BGRA in memory
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }
}
