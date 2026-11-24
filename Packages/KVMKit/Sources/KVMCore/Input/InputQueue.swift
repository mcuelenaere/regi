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
///
/// `latestOnly` turns it into a sender of *state* rather than events, for a
/// device that handles each request concurrently. JetKVM runs every JSON-RPC
/// message in its own goroutine, so two requests in flight can be applied in
/// either order (a quick hide-then-show could leave the video paused while the
/// window is visible). Since the consumer awaits each call, which itself waits
/// for the device's reply, at most one call is ever in flight, and values that
/// were never sent are dropped in favour of the newest: the last value
/// enqueued is always the last one the device sees. Intermediate values are
/// intentionally lost, and a failed call is not retried; the caller decides
/// (the JetKVM backend re-sends its latched state on reconnect).
@MainActor
public final class InputQueue<Message: Sendable> {
    private let continuation: AsyncStream<Message>.Continuation
    private let consumer: Task<Void, Never>

    public init(latestOnly: Bool = false, send: @escaping @Sendable (Message) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Message.self,
            bufferingPolicy: latestOnly ? .bufferingNewest(1) : .unbounded
        )
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
