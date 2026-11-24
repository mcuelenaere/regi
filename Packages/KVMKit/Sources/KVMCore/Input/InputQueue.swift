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
/// Several `enqueue` calls in a row are contiguous (nothing can slip in
/// between them on the main actor). The queue never sleeps; a caller that
/// needs a gap enqueues the later message itself after the wait. The queue
/// idea comes from `ReliableHIDQueue` in PR #16.
@MainActor
public final class InputQueue<Message: Sendable> {
    private let continuation: AsyncStream<Message>.Continuation
    private let consumer: Task<Void, Never>

    public init(send: @escaping @Sendable (Message) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Message.self)
        self.continuation = continuation
        consumer = Task {
            for await message in stream {
                guard !Task.isCancelled else { return }
                await send(message)
            }
        }
    }

    public func enqueue(_ message: Message) {
        continuation.yield(message)
    }

    /// Drop everything not yet sent. Later `enqueue` calls are ignored.
    public func cancel() {
        continuation.finish()
        consumer.cancel()
    }
}
