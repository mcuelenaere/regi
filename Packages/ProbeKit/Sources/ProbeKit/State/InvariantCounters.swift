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
    /// Informational only — **not** a correctness signal, and deliberately
    /// excluded from `isClean`.
    ///
    /// Measured on a real session tap: `CGEventGetTimestamp` is not monotonic
    /// across the stream. Events from different subsystems interleave, and
    /// inversions of ~12 ms show up in ordinary use. (Synthetic events are not
    /// the cause: their timestamp is zero until the window server stamps them
    /// on delivery.) Treating this as a violation would fail every real run.
    ///
    /// Ordering assertions use `seq`, which is assigned on arrival and is
    /// always monotonic. Timestamps are only ever used for durations within a
    /// single key's own down/up pair.
    public var nonMonotonicTimestamp: UInt32 = 0
    /// Tap events with `sourcePID != 0`: something other than the KVM injected
    /// input, so the run is contaminated.
    public var syntheticSourceEvents: UInt32 = 0
    /// Events evicted from the probe's ring before any reader saw them.
    ///
    /// Genuine loss of *evidence*, not of input: the events happened and were
    /// counted, but no one read them before the ring wrapped past them. Stays
    /// at zero for as long as a reader keeps up, however long the run.
    ///
    /// Excluded from `isClean` all the same, because it describes the capture
    /// pipeline rather than the input under test. Whether the *driver* lost
    /// evidence is answered authoritatively by its gap detection against
    /// `oldestSeqInWindow`.
    public var droppedByRing: UInt32 = 0

    /// Cumulative totals of what the target actually received, independent of
    /// how much of the event stream fits through the QR window.
    ///
    /// These exist because counting from the transmitted events cannot work
    /// under load: the window trims to stay legible, so a busy run delivers a
    /// fraction of what happened and any total computed from it understates
    /// reality. Comparing these against the client's own outbound count is the
    /// only sound way to ask "did every transition arrive?" while the input
    /// rate is high enough to provoke the bug.
    ///
    /// Informational, and excluded from `isClean`: a total is only meaningful
    /// next to the sender's.
    public var buttonDowns: UInt32 = 0
    public var buttonUps: UInt32 = 0
    public var keyDowns: UInt32 = 0
    public var keyUps: UInt32 = 0

    public init() {}

    public var isClean: Bool {
        // nonMonotonicTimestamp and droppedByRing are excluded on purpose:
        // both are properties of the capture pipeline rather than of the input
        // being tested. See their declarations.
        upWithoutDown == 0 && duplicateDown == 0 && stuckAtEnd == 0
            && syntheticSourceEvents == 0
    }
}

public struct Violation: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case upWithoutDown(kvk: UInt16)
        case duplicateDown(kvk: UInt16)
        case stuckAtEnd(kvk: UInt16, heldNanos: UInt64)
        case syntheticSource(pid: Int32)
        case buttonUpWithoutDown(button: PointerButton)
        case buttonStuckAtEnd(button: PointerButton)
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
        case .syntheticSource(let pid):
            return "seq \(seq): event injected by pid \(pid) — run contaminated"
        case .buttonUpWithoutDown(let b):
            return "seq \(seq): \(b.label) released with no matching press"
        case .buttonStuckAtEnd(let b):
            return "seq \(seq): \(b.label) still held at the end"
        }
    }
}
