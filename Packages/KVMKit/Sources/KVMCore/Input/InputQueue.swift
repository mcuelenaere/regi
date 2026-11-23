// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Puts input on the wire in exactly the order AppKit delivered it.
///
/// Input callbacks arrive synchronously on the main actor, but the transports
/// are async (an actor hop, a WebSocket send). Spawning a `Task` per event
/// gives no ordering guarantee between those Tasks, and a Task that sends
/// several frames can interleave with the next one at every `await`. This
/// queue removes both problems: `enqueue` is synchronous, and a single
/// long-lived consumer awaits each send before starting the next.
///
/// A batch stays contiguous: nothing else is sent between its messages, and
/// the optional delay is applied only *between* them (e.g. Caps Lock's
/// press, hold, release). The batch/delay design comes from `ReliableHIDQueue`
/// in PR #16.
@MainActor
public final class InputQueue<Message: Sendable> {
    private struct Batch: Sendable {
        let messages: [Message]
        let delay: Duration?
    }

    private let continuation: AsyncStream<Batch>.Continuation
    private let consumer: Task<Void, Never>

    public init(send: @escaping @Sendable (Message) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Batch.self)
        self.continuation = continuation
        consumer = Task {
            for await batch in stream {
                for (index, message) in batch.messages.enumerated() {
                    if index > 0, let delay = batch.delay {
                        do { try await Task.sleep(for: delay) } catch { return }
                    }
                    guard !Task.isCancelled else { return }
                    await send(message)
                }
            }
        }
    }

    public func enqueue(_ message: Message) {
        continuation.yield(Batch(messages: [message], delay: nil))
    }

    public func enqueue(batch messages: [Message], delay: Duration? = nil) {
        guard !messages.isEmpty else { return }
        continuation.yield(Batch(messages: messages, delay: delay))
    }

    /// Drop everything not yet sent. Later `enqueue` calls are ignored.
    public func cancel() {
        continuation.finish()
        consumer.cancel()
    }
}
