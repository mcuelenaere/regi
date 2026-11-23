// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import KVMCore

@MainActor
final class InputQueueTests: XCTestCase {
    /// Collects what the queue sends, with timestamps, and lets the test await N.
    actor Wire {
        var sent: [(String, ContinuousClock.Instant)] = []
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        func record(_ s: String) {
            sent.append((s, .now))
            for (n, c) in waiters where sent.count >= n { c.resume() }
            waiters.removeAll { sent.count >= $0.0 }
        }
        func waitFor(_ n: Int) async {
            if sent.count >= n { return }
            await withCheckedContinuation { waiters.append((n, $0)) }
        }
    }

    func testFIFOAcrossSinglesAndBatchesWithDelayOnlyBetweenBatchMessages() async {
        let wire = Wire()
        // Yield in the sender: a Task-per-event design would reorder here.
        let queue = InputQueue<String> { s in await Task.yield(); await wire.record(s) }
        let delay = Duration.milliseconds(200)

        queue.enqueue("a")
        queue.enqueue(batch: ["b1", "b2", "b3"], delay: delay)
        queue.enqueue("c")
        queue.enqueue(batch: [])            // ignored
        await wire.waitFor(5)

        let sent = await wire.sent
        XCTAssertEqual(sent.map(\.0), ["a", "b1", "b2", "b3", "c"])
        XCTAssertGreaterThanOrEqual(sent[2].1 - sent[1].1, .milliseconds(190))
        XCTAssertGreaterThanOrEqual(sent[3].1 - sent[2].1, .milliseconds(190))
        XCTAssertLessThan(sent[1].1 - sent[0].1, .milliseconds(100))   // before the batch
        XCTAssertLessThan(sent[4].1 - sent[3].1, .milliseconds(100))   // after the batch
    }

    func testNothingSentAfterCancel() async throws {
        let wire = Wire()
        let queue = InputQueue<String> { await wire.record($0) }
        queue.enqueue(batch: ["x", "y"], delay: .milliseconds(100))
        await wire.waitFor(1)               // "x" is out, "y" is waiting on the delay
        queue.cancel()
        queue.enqueue("z")
        try await Task.sleep(for: .milliseconds(300))
        let sent = await wire.sent
        XCTAssertEqual(sent.map(\.0), ["x"])
    }
}
