// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import JetKVMKit

/// The OS Services drop channel: bytes only within the credit the host
/// grants, each message a little-endian transfer ID and a chunk.
final class GuestFileSenderTests: XCTestCase {
    private func file(_ size: Int) throws -> (URL, Data) {
        let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (url, bytes)
    }

    func testSendsWithinCreditAndEndsOnDone() async throws {
        let (url, bytes) = try file(50_000)
        let (messages, input) = AsyncStream<String>.makeStream()
        input.yield(#"{"type":"credit","transfer":7,"bytes":40000}"#)
        input.yield(#"{"type":"credit","transfer":7,"bytes":524288}"#)
        input.yield(#"{"type":"done","transfer":7,"status":"ok"}"#)
        // Not finished: `run` must return once every transfer is done.

        var frames: [Data] = []
        let statuses = await GuestFileSender.run(
            [.init(url: url, size: 50_000, transfer: 7)],
            messages: messages,
            send: { data, isBinary in
                XCTAssertTrue(isBinary)
                frames.append(data)
                return true
            },
            progress: { _ in }
        )

        XCTAssertEqual(statuses, [7: "ok"])
        // 32 KiB chunks, never past the credit (40000) or the file's end.
        XCTAssertEqual(frames.map(\.count), [4 + 32_768, 4 + 7_232, 4 + 10_000])
        for frame in frames { XCTAssertEqual(Array(frame.prefix(4)), [7, 0, 0, 0]) }
        XCTAssertEqual(Data(frames.map { $0.dropFirst(4) }.joined()), bytes)
    }

    func testNothingMovesWithoutCreditAndCloseEndsTheDrop() async throws {
        let (first, _) = try file(10)
        let (second, _) = try file(10)
        let (messages, input) = AsyncStream<String>.makeStream()
        input.yield(#"{"type":"credit","transfer":2,"bytes":524288}"#)
        input.yield(#"{"type":"done","transfer":2,"status":"ok"}"#)
        input.finish() // channel closed before transfer 3 got credit

        var frames: [Data] = []
        let statuses = await GuestFileSender.run(
            [.init(url: first, size: 10, transfer: 2), .init(url: second, size: 10, transfer: 3)],
            messages: messages,
            send: { data, _ in frames.append(data); return true },
            progress: { _ in }
        )

        XCTAssertEqual(statuses, [2: "ok"])
        XCTAssertEqual(frames.map { Array($0.prefix(4)) }, [[2, 0, 0, 0]])
    }
}
