import Foundation

/// Fixed-capacity ring of captured events.
///
/// The producer is a `CGEventTap` callback, which the window server will
/// force-disable if it runs long, so `append` must be a lock, a couple of
/// stores and a return: no allocation, no encoding, no UI work. An
/// `os_unfair_lock` is the right primitive here — there are at most two
/// threads and each critical section is a handful of instructions.
public final class ProbeEventRing: @unchecked Sendable {
    private let capacity: Int
    private var storage: [ProbeEvent?]
    private var writeIndex = 0
    private var lock = os_unfair_lock()

    public private(set) var nextSeq: UInt64 = 1
    public private(set) var oldestAvailableSeq: UInt64 = 1
    public private(set) var dropped: UInt32 = 0

    /// Cumulative held-state, fed exactly once per event as it is captured.
    ///
    /// This deliberately does not live at the read sites. Replaying a fresh
    /// tracker over `recent(n)` — which is what the probe and the QR renderer
    /// used to do — manufactures violations out of nothing: once a press
    /// scrolls off the front of the window while its release is still inside,
    /// the replay sees a release with no matching press and reports it. Every
    /// busy run produced phantom `upWithoutDown`s that way, which is worse
    /// than useless in a tool whose whole job is to say whether the input
    /// arrived intact.
    ///
    /// Ingest is a dictionary insert or removal, which is within the budget
    /// `append` documents; violations are appended only when one actually
    /// occurs, and the tracker caps what it retains.
    private var tracker = HeldStateTracker()

    /// What has been held and what has gone wrong since the run began —
    /// independent of how much of the window is still resident.
    public struct LiveState: Sendable {
        public var counters: InvariantCounters
        public var violations: [Violation]
        public var heldKeys: [UInt16: HeldStateTracker.Hold]
        public var heldButtons: [PointerButton: HeldStateTracker.Hold]
    }

    public init(capacity: Int = 4096) {
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    /// Assigns the sequence number and stores the event. Returns the seq so the
    /// caller can correlate without taking the lock again.
    @discardableResult
    public func append(machAbsoluteNanos: UInt64, payload: ProbeEvent.Payload) -> UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let seq = nextSeq
        nextSeq += 1

        if let evicted = storage[writeIndex] {
            // Overwriting an unread event: the window moved past it. Counted and
            // surfaced, because a driver that misses this would assert over a
            // partial record.
            dropped &+= 1
            oldestAvailableSeq = evicted.seq + 1
        }
        let event = ProbeEvent(seq: seq, machAbsoluteNanos: machAbsoluteNanos,
                               payload: payload)
        storage[writeIndex] = event
        writeIndex = (writeIndex + 1) % capacity
        tracker.ingest(event)
        return seq
    }

    /// The most recent `limit` events, oldest first.
    public func recent(_ limit: Int) -> (events: [ProbeEvent], oldestAvailableSeq: UInt64, dropped: UInt32) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        var out: [ProbeEvent] = []
        out.reserveCapacity(min(limit, capacity))
        var idx = (writeIndex - 1 + capacity) % capacity
        for _ in 0..<min(limit, capacity) {
            guard let e = storage[idx] else { break }
            out.append(e)
            idx = (idx - 1 + capacity) % capacity
        }
        return (out.reversed(), oldestAvailableSeq, dropped)
    }

    /// Snapshot of the cumulative tracker. Cheap: four small copies.
    public func liveState() -> LiveState {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        var c = tracker.counters
        c.droppedByRing = dropped
        return LiveState(counters: c,
                         violations: tracker.violations,
                         heldKeys: tracker.heldKeys,
                         heldButtons: tracker.heldButtons)
    }

    public func reset() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0
        oldestAvailableSeq = nextSeq
        dropped = 0
        tracker = HeldStateTracker()
    }
}
