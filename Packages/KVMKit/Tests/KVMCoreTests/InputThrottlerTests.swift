import XCTest
@testable import KVMCore

final class InputThrottlerTests: XCTestCase {

    func testFirstCallEmits() {
        var throttler = InputThrottler(interval: .milliseconds(8))
        let now = ContinuousClock().now
        XCTAssertTrue(throttler.shouldEmit(at: now))
    }

    func testSecondCallWithinIntervalDrops() {
        var throttler = InputThrottler(interval: .milliseconds(8))
        let t0 = ContinuousClock().now
        XCTAssertTrue(throttler.shouldEmit(at: t0))
        XCTAssertFalse(throttler.shouldEmit(at: t0.advanced(by: .milliseconds(4))))
    }

    func testCallAfterIntervalEmits() {
        var throttler = InputThrottler(interval: .milliseconds(8))
        let t0 = ContinuousClock().now
        XCTAssertTrue(throttler.shouldEmit(at: t0))
        XCTAssertTrue(throttler.shouldEmit(at: t0.advanced(by: .milliseconds(8))))
    }

    func testDroppedCallDoesNotResetTimer() {
        // If shouldEmit returned false, the clock should still be
        // anchored to the *last accepted* instant, not the dropped one.
        var throttler = InputThrottler(interval: .milliseconds(8))
        let t0 = ContinuousClock().now
        XCTAssertTrue(throttler.shouldEmit(at: t0))
        // Dropped at t0+4ms
        XCTAssertFalse(throttler.shouldEmit(at: t0.advanced(by: .milliseconds(4))))
        // At t0+8ms exactly, the *original* t0 is the anchor, so this should pass.
        XCTAssertTrue(throttler.shouldEmit(at: t0.advanced(by: .milliseconds(8))))
    }

    func testResetAllowsImmediateEmit() {
        var throttler = InputThrottler(interval: .milliseconds(8))
        let t0 = ContinuousClock().now
        XCTAssertTrue(throttler.shouldEmit(at: t0))
        throttler.reset()
        // Right after reset, any time should be accepted.
        XCTAssertTrue(throttler.shouldEmit(at: t0))
    }
}
