import CoreGraphics

/// The absolute-pointer coordinate space shared by every backend.
///
/// Position is carried as a 15-bit fraction of the source extent, `0...32767`
/// on each axis, with the origin top-left. The value is the wire protocol's,
/// not ours: JetKVM's `pointerReport`, PiKVM's `mouse_move` (which remaps it
/// onto `-32768...32767`) and VNC's pixel mapping all speak it.
///
/// It lives here because it was written out by hand in every one of those
/// places plus the view that produces the coordinates, so nothing tied the
/// mapping to its inverse. A conversion and the check for whether a move is
/// large enough to matter can disagree silently, which is a bug that shows up
/// as input quietly going missing rather than as anything failing.
public enum AbsolutePointer {
    /// Largest value on either axis. The space is `0...maxValue` inclusive.
    public static let maxValue: CGFloat = 32767

    /// Normalized units that one source pixel spans, for a source `extent`
    /// pixels wide or tall.
    ///
    /// The reciprocal of the mapping: a move smaller than this cannot change
    /// which pixel the host resolves, whatever rounding it applies.
    public static func unitsPerPixel(sourceExtent: CGFloat) -> CGFloat {
        guard sourceExtent > 0 else { return 1 }
        return maxValue / sourceExtent
    }

    /// Largest value on either axis, as an integer, for callers clamping in
    /// integer space.
    public static let maxInt = Int(32767)

    /// Resolve a normalized coordinate to a zero-based pixel index within a
    /// surface `extent` pixels across.
    ///
    /// Note the `extent - 1`: the result indexes a pixel, so the top of the
    /// wire range maps to the *last* pixel rather than one past the end. That
    /// is not the inverse of `normalize`, which maps a position within the
    /// extent, and the two are deliberately separate for that reason.
    public static func pixelIndex(fromNormalized n: Int32, extent: Int) -> Int {
        guard extent > 0 else { return 0 }
        let clamped = max(0, min(maxInt, Int(n)))
        return Int((Double(clamped) / Double(maxInt)) * Double(extent - 1))
    }

    /// Normalize a position within `extent` onto the wire range.
    public static func normalize(_ value: CGFloat, extent: CGFloat) -> Int32 {
        guard extent > 0 else { return 0 }
        return Int32(max(0, min(extent, value)) / extent * maxValue)
    }
}
