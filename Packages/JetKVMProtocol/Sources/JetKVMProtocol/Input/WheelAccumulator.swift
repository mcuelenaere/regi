import Foundation

/// Accumulates fractional scroll-wheel deltas (from e.g. macOS
/// trackpad `NSEvent.scrollingDeltaY`) and drains them as integer
/// HID wheel detents.
///
/// Why: macOS trackpads fire `NSEvent.scrollWheel` at 60-120 Hz with
/// sub-detent deltas (typically 1-5 raw units during a slow swipe).
/// Emitting one ±1 detent per event over-scrolls the host by an
/// order of magnitude and feels chunky. Accumulating fractional
/// deltas, then draining the integer part at a fixed rate (~60 Hz),
/// preserves the *integral* of scroll input — the host gets the
/// same total amount of scroll the user dragged, smoothed over a
/// human-perceivable cadence.
///
/// Two-axis: separate accumulators for Y and X, identical math.
///
/// Sign convention: positive deltas accumulate to positive emitted
/// detents (HID wheel "up" = positive, matching
/// `NSEvent.scrollingDeltaY`'s convention). Direction reversals
/// just keep adding signed deltas — the integral handles
/// cancellation naturally.
///
/// Designed to be testable in isolation: no clock, no I/O. The
/// caller (typically a view) owns the throttle that decides when
/// to call `flushInteger()`.
public struct WheelAccumulator: Sendable {
    /// Divisor applied to each incoming raw delta before
    /// accumulation. Higher = less sensitive (more raw input needed
    /// per detent). Tuned for "a slow 1-second trackpad swipe
    /// produces ~3 detents."
    public let scale: Double

    /// Maximum absolute value of any single emitted axis. The
    /// residual beyond the cap stays in the accumulator and drains
    /// across subsequent `flushInteger()` calls — useful for
    /// taming flicks where a single event delivers a huge delta.
    public let capPerEmit: Int8

    private var accumulatorY: Double = 0
    private var accumulatorX: Double = 0

    public init(scale: Double, capPerEmit: Int8) {
        precondition(scale > 0, "scale must be positive")
        precondition(capPerEmit > 0, "capPerEmit must be positive")
        self.scale = scale
        self.capPerEmit = capPerEmit
    }

    /// Add raw delta values (in NSEvent.scrollingDelta units) to
    /// each axis. The values are divided by `scale` internally.
    public mutating func add(deltaY: Double, deltaX: Double) {
        accumulatorY += deltaY / scale
        accumulatorX += deltaX / scale
    }

    /// Drain the integer part of each axis, capped at ±`capPerEmit`.
    /// The fractional remainder (plus any residual beyond the cap)
    /// stays in the accumulator for the next call.
    ///
    /// `trunc()` (floor-toward-zero) is used instead of `floor()` so
    /// negative residuals don't accidentally over-emit by one
    /// detent: `trunc(-0.7) == -0.0`, not `-1.0`.
    public mutating func flushInteger() -> (y: Int8, x: Int8) {
        let y = Self.drain(&accumulatorY, cap: capPerEmit)
        let x = Self.drain(&accumulatorX, cap: capPerEmit)
        return (y, x)
    }

    /// Zero both accumulators. Use on gesture start (`phase ==
    /// .began`) and on cancellation (`phase == .cancelled`) to
    /// avoid residual from a stale gesture bleeding into the next.
    public mutating func reset() {
        accumulatorY = 0
        accumulatorX = 0
    }

    /// True iff either accumulator carries a non-zero residual.
    /// Mostly useful for debug introspection.
    public var hasResidual: Bool {
        accumulatorY != 0 || accumulatorX != 0
    }

    /// Static so it can take an `inout` reference to a stored
    /// property without overlapping access on `self`.
    private static func drain(_ accumulator: inout Double, cap: Int8) -> Int8 {
        let integerPart = trunc(accumulator)
        // Clamp to ±cap. The remainder beyond the cap stays in the
        // accumulator (intentional — see `capPerEmit` doc).
        let capD = Double(cap)
        let emitted = max(-capD, min(capD, integerPart))
        accumulator -= emitted
        return Int8(emitted)
    }
}
