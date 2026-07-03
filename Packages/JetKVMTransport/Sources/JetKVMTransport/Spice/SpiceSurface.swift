import Foundation

/// A SPICE drawing surface: a top-down BGRA8888 framebuffer the display
/// channel composites draw ops into. The primary surface is what we hand to
/// the renderer as video frames.
final class SpiceSurface {
    let width: Int
    let height: Int
    /// BGRA, row-major, top-down. `width * height * 4` bytes.
    private(set) var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }

    /// Fill `rect` with a solid color (SPICE 0x00RRGGBB), clamped to bounds.
    func fill(rect: SpiceRect, color: UInt32) {
        let b = UInt8(color & 0xFF)
        let g = UInt8((color >> 8) & 0xFF)
        let r = UInt8((color >> 16) & 0xFF)
        let (x0, y0, w, h) = clampedRegion(destLeft: Int(rect.left), destTop: Int(rect.top),
                                           w: rect.width, h: rect.height)
        guard w > 0, h > 0 else { return }
        pixels.withUnsafeMutableBufferPointer { buf in
            for row in 0..<h {
                var i = ((y0 + row) * width + x0) * 4
                for _ in 0..<w {
                    buf[i] = b; buf[i + 1] = g; buf[i + 2] = r; buf[i + 3] = 0xFF
                    i += 4
                }
            }
        }
    }

    /// Blit a top-down BGRA source (its `srcArea` sub-rect) into `dest`.
    /// v1 assumes 1:1 (no scaling); dimensions are clamped to both buffers.
    func blit(src: [UInt8], srcWidth: Int, srcHeight: Int,
              srcArea: SpiceRect, dest: SpiceRect) {
        let srcLeft = max(0, Int(srcArea.left))
        let srcTop = max(0, Int(srcArea.top))
        var w = min(srcArea.width, dest.width)
        var h = min(srcArea.height, dest.height)
        w = min(w, srcWidth - srcLeft)
        h = min(h, srcHeight - srcTop)
        let (dx, dy, cw, ch) = clampedRegion(destLeft: Int(dest.left), destTop: Int(dest.top),
                                             w: w, h: h)
        guard cw > 0, ch > 0 else { return }
        guard src.count >= (srcTop + ch) * srcWidth * 4 else { return }

        pixels.withUnsafeMutableBufferPointer { dst in
            src.withUnsafeBufferPointer { s in
                for row in 0..<ch {
                    let sRow = ((srcTop + row) * srcWidth + srcLeft) * 4
                    let dRow = ((dy + row) * width + dx) * 4
                    for i in 0..<(cw * 4) { dst[dRow + i] = s[sRow + i] }
                }
            }
        }
    }

    /// Copy a `dest`-sized block from `(srcX, srcY)` to `dest` within this
    /// same surface (SPICE COPY_BITS — used for scrolling / window drags).
    /// Source and destination regions may overlap, so the source is
    /// snapshotted into a scratch buffer first. Both ends are clamped.
    func copyBits(srcX: Int, srcY: Int, dest: SpiceRect) {
        var (dx, dy, cw, ch) = clampedRegion(destLeft: Int(dest.left), destTop: Int(dest.top),
                                             w: dest.width, h: dest.height)
        let sx = max(0, srcX), sy = max(0, srcY)
        // A clamped-up source origin shifts the destination start to match, so
        // corresponding pixels stay aligned.
        dx += (sx - srcX); dy += (sy - srcY)
        cw = min(cw, width - sx)
        ch = min(ch, height - sy)
        guard cw > 0, ch > 0, dx >= 0, dy >= 0, dx + cw <= width, dy + ch <= height else { return }

        let rowBytes = cw * 4
        var scratch = [UInt8](repeating: 0, count: rowBytes * ch)
        pixels.withUnsafeMutableBufferPointer { buf in
            scratch.withUnsafeMutableBufferPointer { tmp in
                for row in 0..<ch {
                    let sRow = ((sy + row) * width + sx) * 4
                    for i in 0..<rowBytes { tmp[row * rowBytes + i] = buf[sRow + i] }
                }
                for row in 0..<ch {
                    let dRow = ((dy + row) * width + dx) * 4
                    for i in 0..<rowBytes { buf[dRow + i] = tmp[row * rowBytes + i] }
                }
            }
        }
    }

    /// Clamp a destination region to the surface, returning the usable
    /// origin + size (all non-negative, within bounds).
    private func clampedRegion(destLeft: Int, destTop: Int, w: Int, h: Int)
        -> (x: Int, y: Int, w: Int, h: Int) {
        let x = max(0, destLeft)
        let y = max(0, destTop)
        let cw = min(w - (x - destLeft), width - x)
        let ch = min(h - (y - destTop), height - y)
        return (x, y, max(0, cw), max(0, ch))
    }
}
