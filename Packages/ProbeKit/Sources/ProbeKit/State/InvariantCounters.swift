import Foundation

/// The counters that catch the bug classes this whole harness exists for:
/// a key that never arrives, a click that arrives twice, a modifier left held.
public struct InvariantCounters: Sendable, Equatable {
    /// A release with no matching press. Almost always means a press was lost.
    public var upWithoutDown: UInt32 = 0
    /// A press while already held, excluding OS autorepeat. On the target this
    /// means the client re-sent a press it had already sent.
    public var duplicateDown: UInt32 = 0
    /// Still held when the run closed — the stuck-modifier bug, caught directly.
    public var stuckAtEnd: UInt32 = 0
    public var nonMonotonicTimestamp: UInt32 = 0
    /// Tap events with `sourcePID != 0`: something other than the KVM injected
    /// input, so the run is contaminated.
    public var syntheticSourceEvents: UInt32 = 0
    public var droppedByRing: UInt32 = 0

    public init() {}

    public var isClean: Bool {
        upWithoutDown == 0 && duplicateDown == 0 && stuckAtEnd == 0
            && nonMonotonicTimestamp == 0 && syntheticSourceEvents == 0 && droppedByRing == 0
    }
}

public struct Violation: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case upWithoutDown(kvk: UInt16)
        case duplicateDown(kvk: UInt16)
        case stuckAtEnd(kvk: UInt16, heldNanos: UInt64)
        case nonMonotonicTimestamp(previous: UInt64, current: UInt64)
        case syntheticSource(pid: Int32)
    }
    public var kind: Kind
    public var seq: UInt64

    public init(kind: Kind, seq: UInt64) { self.kind = kind; self.seq = seq }

    public var description: String {
        switch kind {
        case .upWithoutDown(let k):
            return "seq \(seq): release of \(KeyLabels.label(k)) with no matching press"
        case .duplicateDown(let k):
            return "seq \(seq): \(KeyLabels.label(k)) pressed while already held"
        case .stuckAtEnd(let k, let n):
            return "seq \(seq): \(KeyLabels.label(k)) still held after \(n / 1_000_000)ms"
        case .nonMonotonicTimestamp(let p, let c):
            return "seq \(seq): timestamp went backwards (\(p) → \(c))"
        case .syntheticSource(let pid):
            return "seq \(seq): event injected by pid \(pid) — run contaminated"
        }
    }
}
