import Foundation
import ProbeKit

/// Merges the sliding windows arriving in successive frames into one ordered
/// record, and — more importantly — detects when that record has a hole in it.
///
/// Frames carry the most recent N events, not a delta, so consecutive reads
/// overlap heavily. Overlap is fine; a *gap* is not. If events fell out of the
/// probe's window before we read them, the record is incomplete and any
/// assertion over it could pass for the wrong reason.
public struct TelemetryAccumulator {
    public enum Fault: Error, CustomStringConvertible, Equatable {
        case gap(expectedFrom: UInt64, oldestAvailable: UInt64, lost: UInt64)
        case epochChanged(from: UInt32, to: UInt32)
        case wireVersionChanged(from: UInt32, to: UInt32)

        public var description: String {
            switch self {
            case .gap(let from, let oldest, let lost):
                return "GAP: \(lost) event(s) lost — expected seq \(from), "
                     + "oldest still available is \(oldest). The record is "
                     + "incomplete, so any run over it must fail."
            case .epochChanged(let a, let b):
                return "probe restarted mid-session (epoch \(a) → \(b)); "
                     + "sequence numbers restarted, so the record cannot be spliced"
            case .wireVersionChanged(let a, let b):
                return "wire version changed (\(a) → \(b))"
            }
        }
    }

    public private(set) var epoch: UInt32?
    public private(set) var lastSeqSeen: UInt64 = 0
    public private(set) var lastFrameIndex: UInt32?
    public private(set) var totalEvents = 0
    public private(set) var faults: [Fault] = []

    public init() {}

    /// Returns the events in this frame not seen before, oldest first.
    /// Throws on a fault rather than papering over it.
    public mutating func ingest(_ frame: TelemetryFrame) throws -> [ProbeEvent] {
        if let epoch, epoch != frame.epoch {
            let f = Fault.epochChanged(from: epoch, to: frame.epoch)
            faults.append(f)
            throw f
        }
        epoch = frame.epoch

        // A re-read of a frame we already have is normal: the probe holds each
        // code on screen for a dwell interval so the encoder settles.
        if let last = lastFrameIndex, frame.frameIndex == last { return [] }
        lastFrameIndex = frame.frameIndex

        if lastSeqSeen > 0, frame.oldestSeqInWindow > lastSeqSeen + 1 {
            let f = Fault.gap(expectedFrom: lastSeqSeen + 1,
                              oldestAvailable: frame.oldestSeqInWindow,
                              lost: frame.oldestSeqInWindow - lastSeqSeen - 1)
            faults.append(f)
            throw f
        }

        let fresh = frame.events.filter { $0.seq > lastSeqSeen }
        if let newest = fresh.last?.seq { lastSeqSeen = newest }
        totalEvents += fresh.count
        return fresh
    }
}
