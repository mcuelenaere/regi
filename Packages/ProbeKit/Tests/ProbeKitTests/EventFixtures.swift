import Foundation
@testable import ProbeKit

/// Realistic traffic, deliberately **not** repetitive.
///
/// A first cut of these fixtures cycled through a handful of fixed patterns and
/// LZFSE compressed 5,000 events into 384 bytes — a density figure that would
/// have sized the QR symbol far too small for real input. Timings, coordinates
/// and keycodes are therefore jittered from a seeded PRNG: deterministic across
/// runs, but with the entropy real input has.
enum Fixtures {
    struct RNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64 = 0x5DEECE66D) { state = seed }
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            Int(next() % UInt64(range.count)) + range.lowerBound
        }
        /// Microsecond-aligned nanosecond gap. The wire carries µs, so
        /// unaligned fixtures would fail round-trip equality for a reason that
        /// has nothing to do with the code under test.
        mutating func gapNanos(_ microsRange: ClosedRange<Int>) -> UInt64 {
            UInt64(int(microsRange)) * 1_000
        }
    }

    static let letters: [UInt16] = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                                    0x09, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x1F,
                                    0x20, 0x22, 0x23, 0x25, 0x26, 0x28, 0x2D, 0x2E]

    /// Typing: down/up pairs with human-ish jittered gaps and varied keys.
    static func typing(events count: Int, seed: UInt64 = 1) -> [ProbeEvent] {
        var rng = RNG(seed: seed)
        var out: [ProbeEvent] = []
        var seq: UInt64 = 1
        var t: UInt64 = 1_000_000_000
        while out.count < count {
            let kvk = letters[rng.int(0...(letters.count - 1))]
            let ch = KeyLabels.label(kvk).lowercased()
            for down in [true, false] where out.count < count {
                out.append(.init(seq: seq, machAbsoluteNanos: t,
                                 payload: .key(.init(kvk: kvk, down: down,
                                                     rawFlags: 0x100, characters: ch))))
                seq += 1
                t += rng.gapNanos(25_000...95_000)
            }
        }
        return out
    }

    /// A drag along a wobbling path — real pointer motion is not a straight
    /// line with constant deltas.
    static func drag(events count: Int, seed: UInt64 = 2) -> [ProbeEvent] {
        var rng = RNG(seed: seed)
        var out: [ProbeEvent] = []
        var seq: UInt64 = 1
        var t: UInt64 = 1_000_000_000
        var x = 400, y = 300

        out.append(.init(seq: seq, machAbsoluteNanos: t,
                         payload: .pointer(.init(type: 1, x: Int32(x), y: Int32(y), clickState: 1))))
        seq += 1; t += 12_000_000

        while out.count < count - 1 {
            let dx = rng.int(-3...9), dy = rng.int(-4...6)
            x += dx; y += dy
            out.append(.init(seq: seq, machAbsoluteNanos: t,
                             payload: .pointer(.init(type: 6, x: Int32(x), y: Int32(y),
                                                     deltaX: Int32(dx), deltaY: Int32(dy)))))
            seq += 1
            t += rng.gapNanos(8_000...18_000)
        }
        out.append(.init(seq: seq, machAbsoluteNanos: t,
                         payload: .pointer(.init(type: 2, x: Int32(x), y: Int32(y), clickState: 1))))
        return out
    }

    /// What a real scenario run produces: typing, modifiers, motion, clicks,
    /// scroll — interleaved, jittered, no repeating cycle.
    static func mixed(count: Int, seed: UInt64 = 3) -> [ProbeEvent] {
        var rng = RNG(seed: seed)
        var out: [ProbeEvent] = []
        var seq: UInt64 = 1
        var t: UInt64 = 1_000_000_000
        var x = 640, y = 400
        var flags: UInt64 = 0x100

        while out.count < count {
            switch rng.int(0...9) {
            case 0, 1, 2, 3, 4:
                let kvk = letters[rng.int(0...(letters.count - 1))]
                out.append(.init(seq: seq, machAbsoluteNanos: t,
                                 payload: .key(.init(kvk: kvk, down: rng.int(0...1) == 0,
                                                     rawFlags: flags,
                                                     characters: KeyLabels.label(kvk).lowercased()))))
            case 5:
                let mods: [UInt16] = [0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E, 0x37, 0x36]
                let kvk = mods[rng.int(0...7)]
                // Real CGEventFlags take a handful of distinct values, not
                // arbitrary bit patterns — randomising them would overstate
                // density and size the symbol too large.
                let real: [UInt64] = [0x100, 0x20102, 0x40101, 0x80108, 0x100110, 0x120102]
                flags = real[rng.int(0...(real.count - 1))]
                out.append(.init(seq: seq, machAbsoluteNanos: t,
                                 payload: .flags(.init(kvk: kvk, rawFlags: flags))))
            case 6, 7, 8:
                let dx = rng.int(-12...12), dy = rng.int(-9...9)
                x += dx; y += dy
                out.append(.init(seq: seq, machAbsoluteNanos: t,
                                 payload: .pointer(.init(type: 5, x: Int32(x), y: Int32(y),
                                                         deltaX: Int32(dx), deltaY: Int32(dy)))))
            default:
                out.append(.init(seq: seq, machAbsoluteNanos: t,
                                 payload: .wheel(.init(lineDeltaY: Int32(rng.int(-2...2)),
                                                       pointDeltaY: Int32(rng.int(-40...40))))))
            }
            seq += 1
            t += rng.gapNanos(4_000...60_000)
        }
        return out
    }

    static func frame(_ events: [ProbeEvent], frameIndex: UInt32 = 1) -> TelemetryFrame {
        TelemetryFrame(
            epoch: 7, frameIndex: frameIndex, probeMonotonicNanos: 123_456_789,
            oldestSeqInWindow: events.first?.seq ?? 0,
            health: .init(tapEnabled: true, runActive: true, accessibilityGranted: true),
            heldKeys: [0x38],
            screen: .init(originX: 0, originY: 0, width: 1920, height: 1080, backingScale: 1),
            events: events
        )
    }
}
