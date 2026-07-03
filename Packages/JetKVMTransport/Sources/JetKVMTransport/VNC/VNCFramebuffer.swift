import Foundation

/// The persistent client-side framebuffer, in 32-bit BGRA (matching the pixel
/// format we force via `SetPixelFormat` and `kCVPixelFormatType_32BGRA`). RFB
/// updates are incremental deltas against this buffer; the stream engine blits
/// each rectangle in and then hands the whole buffer to the presenter once per
/// complete `FramebufferUpdate`.
///
/// Not thread-safe by design: it's confined to the stream engine's single
/// decode task. Bounds are rejected (not clamped) so a malformed rectangle
/// fails loudly rather than corrupting adjacent memory.
final class VNCFramebuffer {
    private(set) var width: Int
    private(set) var height: Int
    private var pixels: [UInt8]

    static let bytesPerPixel = 4

    init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.pixels = [UInt8](repeating: 0, count: self.width * self.height * Self.bytesPerPixel)
        setOpaque()
    }

    var bytesPerRow: Int { width * Self.bytesPerPixel }

    /// Resize, preserving nothing (the server always follows a resize with a
    /// full, non-incremental update). Alpha is reset opaque.
    func resize(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        pixels = [UInt8](repeating: 0, count: self.width * self.height * Self.bytesPerPixel)
        setOpaque()
    }

    /// Whether `rect` lies fully within the framebuffer.
    func contains(x: Int, y: Int, w: Int, h: Int) -> Bool {
        x >= 0 && y >= 0 && w >= 0 && h >= 0 && x + w <= width && y + h <= height
    }

    /// Give the presenter a read-only view of the whole buffer.
    func withPixelBytes<T>(_ body: (UnsafeRawBufferPointer) -> T) -> T {
        pixels.withUnsafeBytes(body)
    }

    /// Blit a BGRA rectangle (`src` is `h` rows of `srcBytesPerRow`, at least
    /// `w * 4` bytes each). Throws on out-of-bounds.
    func blitBGRA(
        x: Int, y: Int, w: Int, h: Int,
        src: UnsafeRawBufferPointer, srcBytesPerRow: Int? = nil
    ) throws {
        guard contains(x: x, y: y, w: w, h: h) else {
            throw VNCConnectionError.protocolError("blit out of bounds \(x),\(y) \(w)x\(h) in \(width)x\(height)")
        }
        guard w > 0, h > 0 else { return }
        let srcStride = srcBytesPerRow ?? (w * Self.bytesPerPixel)
        let rowBytes = w * Self.bytesPerPixel
        guard let srcBase = src.baseAddress, src.count >= srcStride * (h - 1) + rowBytes else {
            throw VNCConnectionError.protocolError("blit source too small")
        }
        let dstStride = bytesPerRow
        pixels.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.baseAddress else { return }
            for row in 0..<h {
                let dstOffset = ((y + row) * width + x) * Self.bytesPerPixel
                memcpy(dstBase.advanced(by: dstOffset),
                       srcBase.advanced(by: row * srcStride),
                       rowBytes)
            }
        }
    }

    /// Blit a rectangle of packed 3-byte TPIXELs (R, G, B per pixel, `w*h*3`
    /// bytes) — the Tight compact pixel form — converting to BGRA. Throws on
    /// out-of-bounds or an undersized source.
    func blitTPixels(x: Int, y: Int, w: Int, h: Int, rgb: [UInt8]) throws {
        guard contains(x: x, y: y, w: w, h: h) else {
            throw VNCConnectionError.protocolError("tpixel blit out of bounds")
        }
        guard w > 0, h > 0 else { return }
        guard rgb.count >= w * h * 3 else {
            throw VNCConnectionError.protocolError("tpixel source too small")
        }
        pixels.withUnsafeMutableBytes { dst in
            guard let base = dst.baseAddress else { return }
            for row in 0..<h {
                var dstOffset = ((y + row) * width + x) * Self.bytesPerPixel
                var srcOffset = row * w * 3
                for _ in 0..<w {
                    let r = rgb[srcOffset], g = rgb[srcOffset + 1], b = rgb[srcOffset + 2]
                    base.storeBytes(of: b, toByteOffset: dstOffset, as: UInt8.self)
                    base.storeBytes(of: g, toByteOffset: dstOffset + 1, as: UInt8.self)
                    base.storeBytes(of: r, toByteOffset: dstOffset + 2, as: UInt8.self)
                    base.storeBytes(of: 0xFF, toByteOffset: dstOffset + 3, as: UInt8.self)
                    dstOffset += Self.bytesPerPixel
                    srcOffset += 3
                }
            }
        }
    }

    /// Fill a rectangle with a solid colour (given as B, G, R). Throws on
    /// out-of-bounds.
    func fill(x: Int, y: Int, w: Int, h: Int, b: UInt8, g: UInt8, r: UInt8) throws {
        guard contains(x: x, y: y, w: w, h: h) else {
            throw VNCConnectionError.protocolError("fill out of bounds")
        }
        guard w > 0, h > 0 else { return }
        pixels.withUnsafeMutableBytes { dst in
            guard let base = dst.baseAddress else { return }
            for row in 0..<h {
                var offset = ((y + row) * width + x) * Self.bytesPerPixel
                for _ in 0..<w {
                    base.storeBytes(of: b, toByteOffset: offset, as: UInt8.self)
                    base.storeBytes(of: g, toByteOffset: offset + 1, as: UInt8.self)
                    base.storeBytes(of: r, toByteOffset: offset + 2, as: UInt8.self)
                    base.storeBytes(of: 0xFF, toByteOffset: offset + 3, as: UInt8.self)
                    offset += Self.bytesPerPixel
                }
            }
        }
    }

    /// CopyRect: move an existing rectangle from `srcX,srcY` to `dstX,dstY`.
    /// Overlap-safe via a scratch copy of the source region. Throws if either
    /// region is out of bounds.
    func copyRect(srcX: Int, srcY: Int, dstX: Int, dstY: Int, w: Int, h: Int) throws {
        guard contains(x: srcX, y: srcY, w: w, h: h),
              contains(x: dstX, y: dstY, w: w, h: h) else {
            throw VNCConnectionError.protocolError("copyRect out of bounds")
        }
        guard w > 0, h > 0 else { return }
        let rowBytes = w * Self.bytesPerPixel
        var scratch = [UInt8](repeating: 0, count: rowBytes * h)
        let dstStride = bytesPerRow
        pixels.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            scratch.withUnsafeMutableBytes { sc in
                guard let scBase = sc.baseAddress else { return }
                for row in 0..<h {
                    let srcOffset = ((srcY + row) * width + srcX) * Self.bytesPerPixel
                    memcpy(scBase.advanced(by: row * rowBytes),
                           base.advanced(by: srcOffset), rowBytes)
                }
                for row in 0..<h {
                    let dstOffset = ((dstY + row) * width + dstX) * Self.bytesPerPixel
                    memcpy(base.advanced(by: dstOffset),
                           scBase.advanced(by: row * rowBytes), rowBytes)
                }
            }
        }
    }

    /// Read one pixel as (B, G, R) — for tests.
    func pixelBGR(x: Int, y: Int) -> (UInt8, UInt8, UInt8)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let o = (y * width + x) * Self.bytesPerPixel
        return (pixels[o], pixels[o + 1], pixels[o + 2])
    }

    private func setOpaque() {
        guard !pixels.isEmpty else { return }
        var i = 3
        while i < pixels.count {
            pixels[i] = 0xFF
            i += Self.bytesPerPixel
        }
    }
}
