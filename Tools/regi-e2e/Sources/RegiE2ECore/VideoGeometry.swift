import CoreGraphics
import Foundation

/// Maps a framebuffer pixel on the target to a screen point on the driver, and
/// back.
///
/// The aspect-fit letterbox is computed here rather than read from Regi. That
/// is deliberate: it is a second, independent implementation of
/// `KVMVideoView.videoContentRect`, so if Regi's letterbox math is wrong the
/// cursor lands somewhere unexpected and a test **fails**. Asking Regi for its
/// own rect would hide exactly that class of bug.
public struct VideoGeometry: Equatable {
    /// The video view's frame in screen coordinates, top-left origin — the
    /// space `CGEvent` posting uses, which is also what AX reports.
    public let viewFrame: CGRect
    /// Source resolution of the host's display, e.g. 1920x1080.
    public let sourceSize: CGSize

    public init(viewFrame: CGRect, sourceSize: CGSize) {
        self.viewFrame = viewFrame
        self.sourceSize = sourceSize
    }

    /// The letterboxed/pillarboxed sub-rect the video actually occupies.
    public var contentRect: CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0,
              viewFrame.width > 0, viewFrame.height > 0 else { return viewFrame }
        let viewAspect = viewFrame.width / viewFrame.height
        let videoAspect = sourceSize.width / sourceSize.height
        if videoAspect > viewAspect {
            let h = viewFrame.width / videoAspect          // letterbox top + bottom
            return CGRect(x: viewFrame.minX, y: viewFrame.minY + (viewFrame.height - h) / 2,
                          width: viewFrame.width, height: h)
        } else {
            let w = viewFrame.height * videoAspect         // pillarbox left + right
            return CGRect(x: viewFrame.minX + (viewFrame.width - w) / 2, y: viewFrame.minY,
                          width: w, height: viewFrame.height)
        }
    }

    /// Framebuffer pixels covered by one screen point. This is the floor on
    /// pointer assertion accuracy, and it dominates every other error term:
    /// a 960-point-wide view showing 1920 px can only address every 2nd pixel.
    public var pixelsPerPoint: CGFloat {
        let r = contentRect
        return r.width > 0 ? sourceSize.width / r.width : 0
    }

    /// Targets the centre of the pixel, not its corner — a half-pixel bias is
    /// otherwise enough to land on the neighbour after rounding.
    public func screenPoint(forFramebufferPixel p: CGPoint) -> CGPoint {
        let r = contentRect
        return CGPoint(x: r.minX + (p.x + 0.5) / sourceSize.width * r.width,
                       y: r.minY + (p.y + 0.5) / sourceSize.height * r.height)
    }

    public func framebufferPixel(forScreenPoint p: CGPoint) -> CGPoint {
        let r = contentRect
        guard r.width > 0, r.height > 0 else { return .zero }
        return CGPoint(x: (p.x - r.minX) / r.width * sourceSize.width - 0.5,
                       y: (p.y - r.minY) / r.height * sourceSize.height - 0.5)
    }

    /// Parses Regi's status-strip readout, e.g. "1920×1080". Note the
    /// multiplication sign, not an ASCII 'x'.
    public static func parseResolution(_ text: String) -> CGSize? {
        let parts = text.split(whereSeparator: { $0 == "×" || $0 == "x" || $0 == "X" })
        guard parts.count == 2,
              let w = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }
}

extension AXDriver {
    /// Reads the live geometry out of the running app.
    public func videoGeometry() throws -> VideoGeometry {
        let frame = try self.frame(of: AXID.videoView)
        let text = try self.text(of: AXID.resolutionText)
        guard let size = VideoGeometry.parseResolution(text) else {
            throw DriverError.attributeUnavailable(AXID.resolutionText,
                                                   "a parseable resolution (got \"\(text)\")")
        }
        return VideoGeometry(viewFrame: frame, sourceSize: size)
    }
}
