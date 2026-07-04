import Foundation

/// Drops events that arrive faster than `interval` apart.
///
/// Intended for the absolute pointer (`PointerReport`) path: at the
/// device's native NSEvent rate we'd send hundreds of frames per
/// second over the unreliable channel; capping to ~120 Hz keeps the
/// channel from queueing stale-by-the-time-they-arrive coordinates.
/// Per the plan: under congestion, dropping is better than queuing.
///
/// The strategy is "drop", not "batch" — there's no point coalescing
/// pointer positions because only the latest one matters.
public struct InputThrottler: Sendable {
    public let interval: Duration

    private var lastEmit: ContinuousClock.Instant?

    public init(interval: Duration = .milliseconds(8)) {
        self.interval = interval
    }

    /// Returns `true` if `now` is far enough past the last accepted
    /// time to emit a new event. State updates only on `true` so a
    /// dropped event doesn't reset the clock.
    public mutating func shouldEmit(at now: ContinuousClock.Instant) -> Bool {
        if let last = lastEmit, last.advanced(by: interval) > now {
            return false
        }
        lastEmit = now
        return true
    }

    /// Convenience overload using `ContinuousClock.now` directly.
    public mutating func shouldEmit() -> Bool {
        shouldEmit(at: ContinuousClock().now)
    }

    /// Reset the throttler so the next call to `shouldEmit` is
    /// guaranteed to return `true`.
    public mutating func reset() {
        lastEmit = nil
    }
}
