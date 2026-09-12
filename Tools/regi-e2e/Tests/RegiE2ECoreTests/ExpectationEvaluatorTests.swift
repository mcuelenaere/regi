import ProbeKit
import XCTest
@testable import RegiE2ECore

final class ExpectationEvaluatorTests: XCTestCase {
    private var seq: UInt64 = 0

    private func key(_ kvk: UInt16, _ down: Bool, _ chars: String = "") -> ProbeEvent {
        seq += 1
        return ProbeEvent(seq: seq, machAbsoluteNanos: seq * 10_000_000,
                          payload: .key(.init(kvk: kvk, down: down, characters: chars)))
    }
    private func flags(_ kvk: UInt16, _ raw: UInt64) -> ProbeEvent {
        seq += 1
        return ProbeEvent(seq: seq, machAbsoluteNanos: seq * 10_000_000,
                          payload: .flags(.init(kvk: kvk, rawFlags: raw)))
    }
    private func pointer(_ x: Int32, _ y: Int32) -> ProbeEvent {
        seq += 1
        return ProbeEvent(seq: seq, machAbsoluteNanos: seq * 10_000_000,
                          payload: .pointer(.init(type: 5, x: x, y: y)))
    }

    override func setUp() { seq = 0 }

    // MARK: - Sequences

    func testExactSequenceMatches() {
        let events = [key(0x00, true), key(0x00, false)]
        let r = ExpectationEvaluator.evaluate(.keySequence([.down(0x00), .up(0x00)]), over: events)
        XCTAssertTrue(r.passed, r.detail)
    }

    func testExactSequenceRejectsExtraEvents() {
        let events = [key(0x00, true), key(0x00, false), key(0x0E, true)]
        let r = ExpectationEvaluator.evaluate(.keySequence([.down(0x00), .up(0x00)]), over: events)
        XCTAssertFalse(r.passed)
        XCTAssertTrue(r.detail.contains("got 3"), r.detail)
    }

    /// Pointer traffic must not break a keyboard sequence — motion interleaves
    /// freely and says nothing about key ordering.
    func testSequenceIgnoresPointerTraffic() {
        let events = [key(0x00, true), pointer(10, 10), pointer(11, 11), key(0x00, false)]
        XCTAssertTrue(ExpectationEvaluator.evaluate(.keySequence([.down(0x00), .up(0x00)]),
                                                    over: events).passed)
    }

    func testSubsequenceToleratesExtras() {
        let events = [key(0x00, true), key(0x0E, true), key(0x0E, false), key(0x00, false)]
        XCTAssertTrue(ExpectationEvaluator.evaluate(.keySubsequence([.down(0x00), .up(0x00)]),
                                                    over: events).passed)
        XCTAssertFalse(ExpectationEvaluator.evaluate(.keySequence([.down(0x00), .up(0x00)]),
                                                     over: events).passed)
    }

    /// The character proves modifier state actually reached the target: shift+a
    /// must produce "A" there, not "a".
    func testCharacterMismatchFails() {
        let events = [key(0x00, true, "a"), key(0x00, false, "a")]
        let wantUppercase = Expectation.keySequence([.down(0x00, "A"), .up(0x00, "A")])
        XCTAssertFalse(ExpectationEvaluator.evaluate(wantUppercase, over: events).passed)
        XCTAssertTrue(ExpectationEvaluator.evaluate(
            .keySequence([.down(0x00, "a"), .up(0x00, "a")]), over: events).passed)
    }

    // MARK: - Counts, absence, cursor

    func testAutorepeatTolerantCount() {
        var events = [key(0x25, true)]
        for _ in 0..<4 { events.append(key(0x25, true)) }
        events.append(key(0x25, false))
        XCTAssertTrue(ExpectationEvaluator.evaluate(
            .keyCount(kvk: 0x25, down: true, min: 1, max: 5), over: events).passed)
        XCTAssertTrue(ExpectationEvaluator.evaluate(
            .keyCount(kvk: 0x25, down: false, min: 1, max: 1), over: events).passed)
    }

    func testAbsentDetectsUnexpectedEvents() {
        let clean = ExpectationEvaluator.evaluate(.absent(.gesture), over: [key(0x00, true)])
        XCTAssertTrue(clean.passed, clean.detail)

        let gesture = ProbeEvent(seq: 99, machAbsoluteNanos: 1,
                                 payload: .gesture(.init(kind: .magnify, value: 0.3)))
        let dirty = ExpectationEvaluator.evaluate(.absent(.gesture), over: [gesture])
        XCTAssertFalse(dirty.passed)
        XCTAssertTrue(dirty.detail.contains("unexpected"), dirty.detail)
    }

    func testCursorTolerance() {
        let events = [pointer(958, 541)]
        XCTAssertTrue(ExpectationEvaluator.evaluate(
            .cursorEndsNear(x: 960, y: 540, tolerance: 2), over: events).passed)
        XCTAssertFalse(ExpectationEvaluator.evaluate(
            .cursorEndsNear(x: 960, y: 540, tolerance: 1), over: events).passed)
    }

    func testCursorExpectationFailsWhenNothingArrived() {
        let r = ExpectationEvaluator.evaluate(.cursorEndsNear(x: 1, y: 1, tolerance: 5),
                                              over: [key(0x00, true)])
        XCTAssertFalse(r.passed, "no pointer event must fail rather than pass vacuously")
    }

    // MARK: - The bug classes this exists for

    func testNothingHeldCatchesAStuckKey() {
        let stuck = ExpectationEvaluator.evaluate(.nothingHeld, over: [key(0x38, true)])
        XCTAssertFalse(stuck.passed)
        XCTAssertTrue(stuck.detail.contains("⇧L"), stuck.detail)

        XCTAssertTrue(ExpectationEvaluator.evaluate(
            .nothingHeld, over: [key(0x38, true), key(0x38, false)]).passed)
    }

    func testUnmatchedReleaseIsCaught() {
        let r = ExpectationEvaluator.evaluate(.noUnmatchedReleases, over: [key(0x08, false)])
        XCTAssertFalse(r.passed, r.detail)
    }

    /// The ⌘Tab regression: a modifier left down on the target after the
    /// scenario ends. Read from the last transition's flag bit, because
    /// counting transitions gives the wrong answer after any missed event —
    /// which is exactly the situation this assertion exists to detect.
    func testModifierLeftDownIsCaught() {
        let cmdDown: UInt64 = 0x100108, cmdUp: UInt64 = 0x100
        let stranded = [flags(0x37, cmdDown)]
        let r1 = ExpectationEvaluator.evaluate(.modifierEndsUp(kvk: 0x37), over: stranded)
        XCTAssertFalse(r1.passed)
        XCTAssertTrue(r1.detail.contains("left DOWN"), r1.detail)

        let released = [flags(0x37, cmdDown), flags(0x37, cmdUp)]
        XCTAssertTrue(ExpectationEvaluator.evaluate(.modifierEndsUp(kvk: 0x37),
                                                    over: released).passed)

        // An odd number of transitions ending released: parity would say "down".
        let odd = [flags(0x37, cmdDown), flags(0x37, cmdUp), flags(0x37, cmdDown),
                   flags(0x37, cmdUp), flags(0x37, cmdUp)]
        XCTAssertTrue(ExpectationEvaluator.evaluate(.modifierEndsUp(kvk: 0x37), over: odd).passed,
                      "must read the flag bit, not count transitions")
    }

    func testScenarioRoundTripsThroughJSON() throws {
        let scenario = Scenario(
            id: "key.single", title: "single key", tags: [.keyboard],
            steps: [.key(kvk: 0x00, action: .tap(holdMillis: 40)),
                    .settle(quietMillis: 250, maxMillis: 2000),
                    .expect(.keySequence([.down(0x00), .up(0x00)])),
                    .expect(.nothingHeld)])
        let data = try JSONEncoder().encode(scenario)
        XCTAssertEqual(try JSONDecoder().decode(Scenario.self, from: data), scenario,
                       "scenarios must survive serialisation — replay depends on it")
    }
}
