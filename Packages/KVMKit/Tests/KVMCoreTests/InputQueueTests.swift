// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import KVMCore

@MainActor
final class InputQueueTests: XCTestCase {
    /// Collects what the queue sends, with timestamps, and lets the test await N.
    /// The first send can be held open until released.
    actor Wire {
        var sent: [(String, ContinuousClock.Instant)] = []
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var gate: CheckedContinuation<Void, Never>?
        private var released = false
        func record(_ s: String, blockFirst: Bool = false) async {
            sent.append((s, .now))
            for (n, c) in waiters where sent.count >= n { c.resume() }
            waiters.removeAll { sent.count >= $0.0 }
            if blockFirst, sent.count == 1, !released {
                await withCheckedContinuation { gate = $0 }
            }
        }
        func release() { released = true; gate?.resume(); gate = nil }
        func waitFor(_ n: Int) async {
            if sent.count >= n { return }
            await withCheckedContinuation { waiters.append((n, $0)) }
        }
    }

    func testFIFOAcrossManyEnqueues() async {
        let wire = Wire()
        // Yield in the sender: a Task-per-event design would reorder here.
        let queue = InputQueue<String> { s in await Task.yield(); await wire.record(s) }
        let expected = (0..<50).map(String.init)
        expected.forEach(queue.enqueue)
        await wire.waitFor(expected.count)
        let sent = await wire.sent
        XCTAssertEqual(sent.map(\.0), expected)
    }

    func testNothingSentAfterCancel() async throws {
        let wire = Wire()
        let queue = InputQueue<String> { await wire.record($0) }
        queue.enqueue("x")
        await wire.waitFor(1)
        queue.cancel()
        queue.enqueue("y")
        try await Task.sleep(for: .milliseconds(100))
        let sent = await wire.sent
        XCTAssertEqual(sent.map(\.0), ["x"])
    }

    // MARK: - latestOnly

    func testWhileOneSendIsBlockedOnlyTheNewestFollows() async {
        let wire = Wire()
        let queue = InputQueue<String>(latestOnly: true) { await wire.record($0, blockFirst: true) }
        queue.enqueue("first")
        await wire.waitFor(1)          // "first" is now in flight and blocked
        queue.enqueue("A"); queue.enqueue("B"); queue.enqueue("C")
        await wire.release()
        await wire.waitFor(2)
        try? await Task.sleep(for: .milliseconds(50))
        let sent = await wire.sent
        XCTAssertEqual(sent.map(\.0), ["first", "C"])
    }

    func testNothingSentAfterCancelWhenLatestOnly() async throws {
        let wire = Wire()
        let queue = InputQueue<String>(latestOnly: true) { await wire.record($0) }
        queue.enqueue("x")
        await wire.waitFor(1)
        queue.cancel()
        queue.enqueue("y")
        try await Task.sleep(for: .milliseconds(100))
        let sent = await wire.sent
        XCTAssertEqual(sent.map(\.0), ["x"])
    }
}
