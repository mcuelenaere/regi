import Foundation

/// Decoder for the Hextile encoding (5): each rect is split into 16×16 tiles,
/// row-major, each tile prefixed by a subencoding-mask byte. No compression —
/// a universal, better-than-Raw fallback for servers that don't offer Tight.
/// Pixels are full 4-byte PIXELs in the negotiated 32-bit little-endian BGRA
/// format, so on the wire each is already framebuffer-order B,G,R,X.
final class HextileDecoder {
    private enum Subencoding {
        static let raw: UInt8 = 0x01
        static let backgroundSpecified: UInt8 = 0x02
        static let foregroundSpecified: UInt8 = 0x04
        static let anySubrects: UInt8 = 0x08
        static let subrectsColoured: UInt8 = 0x10
    }

    private static let tileSize = 16

    func decodeRect(
        _ rect: RFBProtocol.RectHeader,
        channel: any VNCByteChannel,
        framebuffer fb: VNCFramebuffer
    ) async throws {
        let w = rect.width, h = rect.height
        guard w > 0, h > 0 else { return }
        var buf = [UInt8](repeating: 0xFF, count: w * h * 4) // alpha pre-set
        // Background / foreground persist across tiles within the rect.
        var bg: (UInt8, UInt8, UInt8) = (0, 0, 0)
        var fg: (UInt8, UInt8, UInt8) = (0, 0, 0)

        var ty = 0
        while ty < h {
            let th = min(Self.tileSize, h - ty)
            var tx = 0
            while tx < w {
                let tw = min(Self.tileSize, w - tx)
                let mask = try await readByte(channel)

                if mask & Subencoding.raw != 0 {
                    let raw = try await channel.readExactly(tw * th * 4)
                    raw.withUnsafeBytes { src in
                        guard let base = src.baseAddress else { return }
                        for row in 0..<th {
                            for col in 0..<tw {
                                let s = (row * tw + col) * 4
                                let b = base.load(fromByteOffset: s, as: UInt8.self)
                                let g = base.load(fromByteOffset: s + 1, as: UInt8.self)
                                let r = base.load(fromByteOffset: s + 2, as: UInt8.self)
                                setPixel(&buf, rectW: w, x: tx + col, y: ty + row, b: b, g: g, r: r)
                            }
                        }
                    }
                    tx += tw
                    continue
                }

                if mask & Subencoding.backgroundSpecified != 0 { bg = try await readPixel(channel) }
                if mask & Subencoding.foregroundSpecified != 0 { fg = try await readPixel(channel) }

                // Paint the whole tile with the background first.
                fillRegion(&buf, rectW: w, x: tx, y: ty, w: tw, h: th, color: bg)

                if mask & Subencoding.anySubrects != 0 {
                    let count = Int(try await readByte(channel))
                    let coloured = (mask & Subencoding.subrectsColoured) != 0
                    for _ in 0..<count {
                        let color = coloured ? try await readPixel(channel) : fg
                        let xy = try await readByte(channel)
                        let wh = try await readByte(channel)
                        let sx = Int(xy >> 4), sy = Int(xy & 0x0F)
                        let sw = Int(wh >> 4) + 1, sh = Int(wh & 0x0F) + 1
                        // Clamp defensively to the tile bounds.
                        let cw = min(sw, tw - sx), ch = min(sh, th - sy)
                        if sx >= 0, sy >= 0, cw > 0, ch > 0 {
                            fillRegion(&buf, rectW: w, x: tx + sx, y: ty + sy, w: cw, h: ch, color: color)
                        }
                    }
                }
                tx += tw
            }
            ty += th
        }

        try buf.withUnsafeBytes {
            try fb.blitBGRA(x: rect.x, y: rect.y, w: w, h: h, src: $0)
        }
    }

    // MARK: - Helpers

    private func readByte(_ channel: any VNCByteChannel) async throws -> UInt8 {
        let d = try await channel.readExactly(1)
        guard let b = d.first else { throw VNCConnectionError.protocolError("Hextile: empty read") }
        return b
    }

    /// Read one 4-byte PIXEL (little-endian BGRA) → (b, g, r).
    private func readPixel(_ channel: any VNCByteChannel) async throws -> (UInt8, UInt8, UInt8) {
        let p = try await channel.readExactly(4)
        return (p[p.startIndex], p[p.startIndex + 1], p[p.startIndex + 2])
    }

    private func setPixel(_ buf: inout [UInt8], rectW: Int, x: Int, y: Int, b: UInt8, g: UInt8, r: UInt8) {
        let o = (y * rectW + x) * 4
        buf[o] = b; buf[o + 1] = g; buf[o + 2] = r; buf[o + 3] = 0xFF
    }

    private func fillRegion(_ buf: inout [UInt8], rectW: Int, x: Int, y: Int, w: Int, h: Int,
                            color: (UInt8, UInt8, UInt8)) {
        for row in 0..<h {
            for col in 0..<w {
                setPixel(&buf, rectW: rectW, x: x + col, y: y + row, b: color.0, g: color.1, r: color.2)
            }
        }
    }
}
