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
        storage[writeIndex] = ProbeEvent(seq: seq, machAbsoluteNanos: machAbsoluteNanos,
                                         payload: payload)
        writeIndex = (writeIndex + 1) % capacity
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

    public func reset() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0
        oldestAvailableSeq = nextSeq
        dropped = 0
    }
}
