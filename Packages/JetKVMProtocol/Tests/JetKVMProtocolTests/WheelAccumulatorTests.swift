import XCTest
@testable import JetKVMProtocol

/// Tests use `scale: 30` to match the production tuning in
/// `KVMVideoView.swift`, so the magic numbers map directly to
/// real-world delta inputs:
///   - raw delta 3.0 / scale 30 = 0.1 (one slow trackpad event)
///   - raw delta 30.0 / scale 30 = 1.0 (one detent's worth)
///   - raw delta 300.0 / scale 30 = 10.0 (cap-saturating)
final class WheelAccumulatorTests: XCTestCase {

    private func makeAccumulator(cap: Int8 = 10) -> WheelAccumulator {
        WheelAccumulator(scale: 30, capPerEmit: cap)
    }

    func testEmptyAccumulatorFlushesZero() {
        var acc = makeAccumulator()
        let (y, x) = acc.flushInteger()
        XCTAssertEqual(y, 0)
        XCTAssertEqual(x, 0)
        XCTAssertFalse(acc.hasResidual)
    }

    /// One slow trackpad event (raw delta 3.0) is below one detent;
    /// nothing emits, residual carries.
    func testSingleSubDetentDelta() {
        var acc = makeAccumulator()
        acc.add(deltaY: 3.0, deltaX: 0)
        let (y, x) = acc.flushInteger()
        XCTAssertEqual(y, 0)
        XCTAssertEqual(x, 0)
        XCTAssertTrue(acc.hasResidual)
    }

    /// Accumulated input crosses the one-detent boundary; emit 1,
    /// keep zero residual.
    func testAccumulatedDetentCrossing() {
        var acc = makeAccumulator()
        acc.add(deltaY: 12.0, deltaX: 0)
        acc.add(deltaY: 12.0, deltaX: 0)
        acc.add(deltaY: 6.0, deltaX: 0) // total 30 → 1.0 internal
        let (y, x) = acc.flushInteger()
        XCTAssertEqual(y, 1)
        XCTAssertEqual(x, 0)
        XCTAssertFalse(acc.hasResidual)
    }

    /// Direction reversal: the integral handles cancellation. A +60
    /// raw input then a -30 raw input nets to +1 detent total.
    /// First flush emits +2 (60/30 = 2). Then -30 lands while
    /// accumulator is at 0 → -1 internal → second flush emits -1.
    func testDirectionReversal() {
        var acc = makeAccumulator()
        acc.add(deltaY: 60.0, deltaX: 0)
        var emit = acc.flushInteger()
        XCTAssertEqual(emit.y, 2)

        acc.add(deltaY: -30.0, deltaX: 0)
        emit = acc.flushInteger()
        XCTAssertEqual(emit.y, -1)
        XCTAssertFalse(acc.hasResidual)
    }

    /// Extreme flick: one huge raw delta. Cap-per-emit clamps the
    /// emit value, residual stays in the accumulator for drainage
    /// in subsequent calls.
    func testCapHonouredWithResidual() {
        var acc = makeAccumulator(cap: 10)
        acc.add(deltaY: 3000.0, deltaX: 0) // 3000/30 = 100 internal
        let first = acc.flushInteger()
        XCTAssertEqual(first.y, 10)
        XCTAssertTrue(acc.hasResidual)

        // Second flush drains another 10, residual is 80.
        let second = acc.flushInteger()
        XCTAssertEqual(second.y, 10)
        XCTAssertTrue(acc.hasResidual)
    }

    /// Y and X accumulators are independent — draining one doesn't
    /// touch the other.
    func testTwoAxisIndependence() {
        var acc = makeAccumulator()
        acc.add(deltaY: 30.0, deltaX: 0)   // 1.0 internal on Y
        // Flush drains Y but X stays at 0.
        var emit = acc.flushInteger()
        XCTAssertEqual(emit.y, 1)
        XCTAssertEqual(emit.x, 0)

        // Now add X only — Y should remain at 0, not pick up
        // residual.
        acc.add(deltaY: 0, deltaX: 60.0)   // 2.0 internal on X
        emit = acc.flushInteger()
        XCTAssertEqual(emit.y, 0)
        XCTAssertEqual(emit.x, 2)
    }

    func testResetZeroesBothAxes() {
        var acc = makeAccumulator()
        acc.add(deltaY: 90.0, deltaX: 45.0) // 3.0 and 1.5 internal
        XCTAssertTrue(acc.hasResidual)
        acc.reset()
        XCTAssertFalse(acc.hasResidual)
        let (y, x) = acc.flushInteger()
        XCTAssertEqual(y, 0)
        XCTAssertEqual(x, 0)
    }

    /// Negative-direction truncation: `trunc(-0.7) == -0.0`, so a
    /// sub-detent negative residual must not over-emit by one in
    /// the negative direction. Two -0.x events sum to -1.1 → emit
    /// -1, residual -0.1.
    func testNegativeTruncationDoesNotOverEmit() {
        var acc = makeAccumulator()
        acc.add(deltaY: -21.0, deltaX: 0) // -0.7 internal
        var emit = acc.flushInteger()
        XCTAssertEqual(emit.y, 0, "single -0.7 must not emit -1")
        XCTAssertTrue(acc.hasResidual)

        acc.add(deltaY: -12.0, deltaX: 0) // -0.4 internal; total -1.1
        emit = acc.flushInteger()
        XCTAssertEqual(emit.y, -1, "after crossing -1, emit -1, keep -0.1")
        XCTAssertTrue(acc.hasResidual)
    }
}
