import Foundation

/// Decoder for the ZRLE encoding (16): a rect is a u32 length + that many bytes
/// of zlib data (one persistent stream per connection), which inflate to a
/// sequence of 64×64 tiles. Each tile is one of: raw CPIXELs, a solid colour, a
/// packed palette, plain RLE, or palette RLE. Efficient and widely supported
/// (RealVNC, TigerVNC, macOS Screen Sharing) — the preferred fallback for
/// servers that don't offer Tight.
///
/// CPIXEL is the 3-byte compact pixel: with our 32-bit little-endian BGRA
/// format the three significant bytes are B, G, R (in wire order) — note this
/// differs from Tight's TPIXEL, which is R, G, B.
final class ZRLEDecoder {
    private let stream = ZlibInflateStream()
    private static let tileSize = 64
    private static let maxRectBytes = 64 * 1024 * 1024

    func reset() { stream.reset() }

    func decodeRect(
        _ rect: RFBProtocol.RectHeader,
        channel: any VNCByteChannel,
        framebuffer fb: VNCFramebuffer
    ) async throws {
        let w = rect.width, h = rect.height
        guard w > 0, h > 0 else { return }

        var header = VNCByteReader(try await channel.readExactly(4))
        let length = Int(try header.readU32())
        guard length >= 0, length <= Self.maxRectBytes else {
            throw VNCConnectionError.protocolError("ZRLE: implausible length \(length)")
        }
        let compressed = length > 0 ? try await channel.readExactly(length) : Data()
        let data = try stream.inflateAll(compressed, limit: Self.maxRectBytes)

        var cursor = ByteCursor(data)
        var buf = [UInt8](repeating: 0xFF, count: w * h * 4)

        var ty = 0
        while ty < h {
            let th = min(Self.tileSize, h - ty)
            var tx = 0
            while tx < w {
                let tw = min(Self.tileSize, w - tx)
                try decodeTile(&cursor, into: &buf, rectW: w, tx: tx, ty: ty, tw: tw, th: th)
                tx += tw
            }
            ty += th
        }

        try buf.withUnsafeBytes {
            try fb.blitBGRA(x: rect.x, y: rect.y, w: w, h: h, src: $0)
        }
    }

    private func decodeTile(
        _ cursor: inout ByteCursor, into buf: inout [UInt8],
        rectW: Int, tx: Int, ty: Int, tw: Int, th: Int
    ) throws {
        let sub = try cursor.u8()
        switch sub {
        case 0: // raw
            for row in 0..<th {
                for col in 0..<tw {
                    let (b, g, r) = try cursor.cpixel()
                    setPixel(&buf, rectW: rectW, x: tx + col, y: ty + row, b: b, g: g, r: r)
                }
            }
        case 1: // solid
            let (b, g, r) = try cursor.cpixel()
            fill(&buf, rectW: rectW, x: tx, y: ty, w: tw, h: th, b: b, g: g, r: r)
        case 2...16: // packed palette
            let paletteSize = Int(sub)
            var palette = [(UInt8, UInt8, UInt8)]()
            palette.reserveCapacity(paletteSize)
            for _ in 0..<paletteSize { palette.append(try cursor.cpixel()) }
            let bpp = paletteSize <= 2 ? 1 : (paletteSize <= 4 ? 2 : 4)
            let indicesPerByte = 8 / bpp
            let mask = UInt8((1 << bpp) - 1)
            for row in 0..<th {
                let rowBytes = (tw + indicesPerByte - 1) / indicesPerByte
                let rowData = try cursor.take(rowBytes)
                let start = rowData.startIndex
                for col in 0..<tw {
                    let byte = rowData[start + col / indicesPerByte]
                    let posInByte = col % indicesPerByte
                    let shift = 8 - bpp * (posInByte + 1)
                    let idx = Int((byte >> UInt8(shift)) & mask)
                    let (b, g, r) = palette[min(idx, paletteSize - 1)]
                    setPixel(&buf, rectW: rectW, x: tx + col, y: ty + row, b: b, g: g, r: r)
                }
            }
        case 128: // plain RLE
            var p = 0
            let total = tw * th
            while p < total {
                let (b, g, r) = try cursor.cpixel()
                var len = try cursor.runLength()
                if len > total - p { len = total - p }
                for _ in 0..<len {
                    setPixel(&buf, rectW: rectW, x: tx + p % tw, y: ty + p / tw, b: b, g: g, r: r)
                    p += 1
                }
            }
        case 130...255: // palette RLE
            let paletteSize = Int(sub) - 128
            var palette = [(UInt8, UInt8, UInt8)]()
            palette.reserveCapacity(paletteSize)
            for _ in 0..<paletteSize { palette.append(try cursor.cpixel()) }
            var p = 0
            let total = tw * th
            while p < total {
                let indexByte = try cursor.u8()
                let paletteIndex = min(Int(indexByte & 0x7F), max(0, paletteSize - 1))
                var len = 1
                if indexByte & 0x80 != 0 { len = try cursor.runLength() }
                if len > total - p { len = total - p }
                let (b, g, r) = palette[paletteIndex]
                for _ in 0..<len {
                    setPixel(&buf, rectW: rectW, x: tx + p % tw, y: ty + p / tw, b: b, g: g, r: r)
                    p += 1
                }
            }
        default:
            throw VNCConnectionError.protocolError("ZRLE: invalid subencoding \(sub)")
        }
    }

    private func setPixel(_ buf: inout [UInt8], rectW: Int, x: Int, y: Int, b: UInt8, g: UInt8, r: UInt8) {
        let o = (y * rectW + x) * 4
        buf[o] = b; buf[o + 1] = g; buf[o + 2] = r; buf[o + 3] = 0xFF
    }

    private func fill(_ buf: inout [UInt8], rectW: Int, x: Int, y: Int, w: Int, h: Int, b: UInt8, g: UInt8, r: UInt8) {
        for row in 0..<h {
            for col in 0..<w {
                setPixel(&buf, rectW: rectW, x: x + col, y: y + row, b: b, g: g, r: r)
            }
        }
    }

    /// Cursor over the inflated tile bytes.
    private struct ByteCursor {
        let bytes: [UInt8]
        var index = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func u8() throws -> UInt8 {
            guard index < bytes.count else { throw VNCConnectionError.protocolError("ZRLE: byte underrun") }
            defer { index += 1 }
            return bytes[index]
        }

        /// A 3-byte CPIXEL → (B, G, R) for the little-endian BGRA format.
        mutating func cpixel() throws -> (UInt8, UInt8, UInt8) {
            guard index + 3 <= bytes.count else { throw VNCConnectionError.protocolError("ZRLE: CPIXEL underrun") }
            let b = bytes[index], g = bytes[index + 1], r = bytes[index + 2]
            index += 3
            return (b, g, r)
        }

        /// RLE run length: one more than the sum of all length bytes, reading
        /// until a byte < 255.
        mutating func runLength() throws -> Int {
            var len = 1
            while true {
                let b = try u8()
                len += Int(b)
                if b != 255 { break }
            }
            return len
        }

        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, index + n <= bytes.count else { throw VNCConnectionError.protocolError("ZRLE: slice underrun") }
            defer { index += n }
            return bytes[index..<index + n]
        }
    }
}
