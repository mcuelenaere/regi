import Foundation

/// Runs over an event stream and reports what is held and what went wrong.
/// Used live by the probe (for the on-screen invariant panel) and again by the
/// driver over a scoped slice (for assertions).
public struct HeldStateTracker: Sendable {
    public struct Hold: Sendable, Equatable {
        public var firstSeq: UInt64
        public var firstNanos: UInt64
        /// OS autorepeats of a key already held. Counted, never treated as a
        /// duplicate press.
        public var repeatCount: UInt32
    }

    public private(set) var heldKeys: [UInt16: Hold] = [:]
    public private(set) var counters = InvariantCounters()
    public private(set) var violations: [Violation] = []
    private var lastNanos: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func ingest(_ event: ProbeEvent) -> [Violation] {
        var new: [Violation] = []

        // Counted, never reported as a violation: a session tap's timestamps
        // are not monotonic across event sources. See InvariantCounters.
        if event.machAbsoluteNanos < lastNanos {
            counters.nonMonotonicTimestamp += 1
        }
        lastNanos = max(lastNanos, event.machAbsoluteNanos)

        switch event.payload {
        case .key(let k):
            if k.sourcePID != 0 {
                counters.syntheticSourceEvents += 1
                new.append(.init(kind: .syntheticSource(pid: k.sourcePID), seq: event.seq))
            }
            if k.down {
                if heldKeys[k.kvk] != nil {
                    // An autorepeat is the OS doing its job; a fresh press of an
                    // already-held key is the client double-sending.
                    if k.autorepeat {
                        heldKeys[k.kvk]?.repeatCount += 1
                    } else {
                        counters.duplicateDown += 1
                        new.append(.init(kind: .duplicateDown(kvk: k.kvk), seq: event.seq))
                    }
                } else {
                    heldKeys[k.kvk] = Hold(firstSeq: event.seq,
                                           firstNanos: event.machAbsoluteNanos,
                                           repeatCount: 0)
                }
            } else {
                if heldKeys.removeValue(forKey: k.kvk) == nil {
                    counters.upWithoutDown += 1
                    new.append(.init(kind: .upWithoutDown(kvk: k.kvk), seq: event.seq))
                }
            }

        case .flags(let f):
            // flagsChanged is a toggle: the keycode identifies which modifier,
            // and whether it is now down has to come from the tracker's own
            // state. This is the same shape ModifierTracker deals with.
            if heldKeys.removeValue(forKey: f.kvk) == nil {
                heldKeys[f.kvk] = Hold(firstSeq: event.seq,
                                       firstNanos: event.machAbsoluteNanos,
                                       repeatCount: 0)
            }

        case .pointer(let p) where p.sourcePID != 0:
            counters.syntheticSourceEvents += 1
            new.append(.init(kind: .syntheticSource(pid: p.sourcePID), seq: event.seq))

        default:
            break
        }

        violations.append(contentsOf: new)
        return new
    }

    /// Call at the end of a scoped slice. Anything still held is the stuck-key
    /// bug — the single most valuable thing this harness detects.
    @discardableResult
    public mutating func finish(atNanos nanos: UInt64 = 0) -> [Violation] {
        var new: [Violation] = []
        for (kvk, hold) in heldKeys.sorted(by: { $0.key < $1.key }) {
            counters.stuckAtEnd += 1
            let held = nanos > hold.firstNanos ? nanos - hold.firstNanos : 0
            new.append(.init(kind: .stuckAtEnd(kvk: kvk, heldNanos: held), seq: hold.firstSeq))
        }
        violations.append(contentsOf: new)
        return new
    }

    public var nothingHeld: Bool { heldKeys.isEmpty }

    /// Hold duration for a key that is currently held, in nanoseconds.
    public func holdDuration(of kvk: UInt16, atNanos nanos: UInt64) -> UInt64? {
        guard let h = heldKeys[kvk], nanos >= h.firstNanos else { return nil }
        return nanos - h.firstNanos
    }
}
