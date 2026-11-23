// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import KVMCore

@MainActor
final class LatestValueSenderTests: XCTestCase {
    /// Records what was sent; the first send can be held open until released.
    actor Wire {
        private(set) var sent: [String] = []
        private var gate: CheckedContinuation<Void, Never>?
        private var released = false
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func record(_ s: String, blockFirst: Bool) async {
            sent.append(s)
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

    func testWhileOneSendIsBlockedOnlyTheNewestFollows() async {
        let wire = Wire()
        let sender = LatestValueSender<String> { await wire.record($0, blockFirst: true) }
        sender.send("first")
        await wire.waitFor(1)          // "first" is now in flight and blocked
        sender.send("A"); sender.send("B"); sender.send("C")
        await wire.release()
        await wire.waitFor(2)
        try? await Task.sleep(for: .milliseconds(50))
        let sent = await wire.sent
        XCTAssertEqual(sent, ["first", "C"])
    }

    func testNothingSentAfterCancel() async throws {
        let wire = Wire()
        let sender = LatestValueSender<String> { await wire.record($0, blockFirst: false) }
        sender.send("x")
        await wire.waitFor(1)
        sender.cancel()
        sender.send("y")
        try await Task.sleep(for: .milliseconds(100))
        let sent = await wire.sent
        XCTAssertEqual(sent, ["x"])
    }
}
