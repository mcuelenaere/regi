import Foundation

/// Counters shared between the decode task (writer) and the backend's ~1 Hz
/// stats sampler (reader). Lock-protected; everything else in the stream engine
/// is confined to the decode task.
final class VNCStatsCollector: @unchecked Sendable {
    struct Snapshot: Sendable {
        var framesPresented: Int = 0
        var decodeTimeSec: Double = 0
        var rawRects: Int = 0
        var copyRects: Int = 0
        var tightRects: Int = 0
        var tightJPEGRects: Int = 0
    }

    private let lock = NSLock()
    private var current = Snapshot()

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func record(frame decodeTime: Double) {
        lock.lock(); defer { lock.unlock() }
        current.framesPresented += 1
        current.decodeTimeSec += decodeTime
    }

    func record(encoding: Int32, jpeg: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        switch encoding {
        case RFBProtocol.Encoding.raw: current.rawRects += 1
        case RFBProtocol.Encoding.copyRect: current.copyRects += 1
        case RFBProtocol.Encoding.tight:
            current.tightRects += 1
            if jpeg { current.tightJPEGRects += 1 }
        default: break
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        current = Snapshot()
    }
}
