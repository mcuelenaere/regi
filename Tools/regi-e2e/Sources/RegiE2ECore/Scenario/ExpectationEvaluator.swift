import CoreGraphics
import Foundation
import ProbeKit

/// Evaluates expectations against a scoped slice of probe events.
///
/// Pure over its inputs, so `replay` can re-evaluate a recorded run offline and
/// reach exactly the same verdict as the live run did.
public enum ExpectationEvaluator {
    public struct Result: Equatable {
        public let passed: Bool
        public let detail: String
    }

    public static func evaluate(_ expectation: Expectation,
                                over events: [ProbeEvent]) -> Result {
        switch expectation {
        case .keySequence(let matchers):
            return matchSequence(matchers, events, exact: true)
        case .keySubsequence(let matchers):
            return matchSequence(matchers, events, exact: false)
        case .keyCount(let kvk, let down, let min, let max):
            let n = events.filter { KeyMatcher(kvk: kvk, down: down).matches($0) }.count
            return Result(passed: n >= min && n <= max,
                          detail: "\(KeyLabels.label(kvk))\(down ? "↓" : "↑") ×\(n), wanted \(min)…\(max)")
        case .absent(let filter):
            let hits = events.filter { matchesKind($0, filter) }
            return Result(passed: hits.isEmpty,
                          detail: hits.isEmpty
                              ? "nothing of kind \(filter.rawValue) arrived, as expected"
                              : "\(hits.count) unexpected \(filter.rawValue) event(s): "
                                + hits.prefix(4).map(\.detail).joined(separator: ", "))
        case .cursorEndsNear(let x, let y, let tolerance):
            guard let last = lastPointer(events) else {
                return Result(passed: false, detail: "no pointer event arrived")
            }
            let dx = Int(last.x) - x, dy = Int(last.y) - y
            return Result(passed: abs(dx) <= tolerance && abs(dy) <= tolerance,
                          detail: "cursor ended (\(Int(last.x)),\(Int(last.y))), "
                                + "wanted (\(x),\(y)) ±\(tolerance) — error (\(dx),\(dy))")
        case .nothingHeld:
            var tracker = HeldStateTracker()
            for e in events { tracker.ingest(e) }
            // Covers buttons as well as keys: a stuck mouse button is the same
            // class of bug as a stuck modifier.
            let held = tracker.heldDescriptions
            return Result(passed: held.isEmpty,
                          detail: held.isEmpty ? "nothing held"
                                               : "still held: \(held.joined(separator: " "))")
        case .noUnmatchedReleases:
            var tracker = HeldStateTracker()
            for e in events { tracker.ingest(e) }
            let n = tracker.counters.upWithoutDown
            return Result(passed: n == 0, detail: "\(n) release(s) without a matching press")
        case .wheelTotal(let axis, let min, let max):
            // Signed total, never a count: the client coalesces wheel events
            // and re-splits them, so only the sum is stable.
            let total = events.reduce(0) { acc, e -> Int in
                guard case .wheel(let w) = e.payload else { return acc }
                return acc + Int(axis == .vertical ? w.lineDeltaY : w.lineDeltaX)
            }
            return Result(passed: total >= min && total <= max,
                          detail: "\(axis.rawValue) wheel total \(total), wanted \(min)…\(max)")

        case .clickCount(let button, let min, let max):
            let want: PointerButton = button == .left ? .left : .right
            let n = events.reduce(0) { acc, e -> Int in
                guard case .pointer(let p) = e.payload,
                      let (b, down) = PointerButton.transition(type: p.type,
                                                               buttonNumber: p.buttonNumber),
                      b == want, down else { return acc }
                return acc + 1
            }
            return Result(passed: n >= min && n <= max,
                          detail: "\(want.label) pressed \(n)×, wanted \(min)…\(max)")

        case .modifierEndsUp(let kvk):
            // Reads the last transition's flag bit rather than counting
            // transitions: parity would report the wrong answer after any
            // missed event, which is the very bug this assertion exists for.
            let last = events.reversed().compactMap { e -> Bool? in
                guard case .flags(let f) = e.payload, f.kvk == kvk else { return nil }
                return ModifierFlagBits.isDown(kvk: f.kvk, rawFlags: f.rawFlags)
            }.first
            guard let last else {
                return Result(passed: false,
                              detail: "no \(KeyLabels.label(kvk)) transition arrived")
            }
            return Result(passed: !last,
                          detail: last ? "\(KeyLabels.label(kvk)) left DOWN on the target"
                                       : "\(KeyLabels.label(kvk)) correctly released")
        }
    }

    private static func matchSequence(_ matchers: [KeyMatcher], _ events: [ProbeEvent],
                                      exact: Bool) -> Result {
        let keyEvents = events.filter { isKeyLike($0) }
        if exact {
            guard keyEvents.count == matchers.count else {
                return Result(passed: false,
                              detail: "wanted \(matchers.count) key events, got \(keyEvents.count): "
                                    + render(keyEvents))
            }
            for (m, e) in zip(matchers, keyEvents) where !m.matches(e) {
                return Result(passed: false,
                              detail: "wanted [\(matchers.map(\.description).joined(separator: ", "))], "
                                    + "got [\(render(keyEvents))]")
            }
            return Result(passed: true, detail: render(keyEvents))
        }
        var remaining = matchers[...]
        for e in keyEvents where remaining.first?.matches(e) == true {
            remaining = remaining.dropFirst()
        }
        return Result(passed: remaining.isEmpty,
                      detail: remaining.isEmpty
                          ? "all \(matchers.count) matched in order"
                          : "never matched: \(remaining.map(\.description).joined(separator: ", "))"
                            + " — saw [\(render(keyEvents))]")
    }

    private static func isKeyLike(_ e: ProbeEvent) -> Bool {
        switch e.payload {
        case .key, .flags: return true
        default: return false
        }
    }

    private static func render(_ events: [ProbeEvent]) -> String {
        events.prefix(12).map(\.detail).joined(separator: ", ")
            + (events.count > 12 ? " …(\(events.count - 12) more)" : "")
    }

    private static func lastPointer(_ events: [ProbeEvent]) -> CGPoint? {
        events.reversed().compactMap { e -> CGPoint? in
            if case .pointer(let p) = e.payload { return CGPoint(x: Int(p.x), y: Int(p.y)) }
            return nil
        }.first
    }

    private static func matchesKind(_ e: ProbeEvent, _ filter: Expectation.KindFilter) -> Bool {
        switch (e.payload, filter) {
        case (_, .any):             return true
        case (.key, .key), (.flags, .key):   return true
        case (.pointer, .pointer):  return true
        case (.wheel, .wheel):      return true
        case (.gesture, .gesture):  return true
        default:                    return false
        }
    }
}
