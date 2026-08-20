import Foundation
import KVMWebRTC

/// Serializes keyboard traffic before it reaches WebRTC's ordered data
/// channel.
///
/// `WebRTCFacade` is an actor, so starting a separate `Task` for every
/// key transition does not preserve the order in which the synchronous
/// AppKit callbacks created those tasks.  A modifier chord can therefore
/// arrive as Tab-down before Control-down, or Control-up before Tab-up.
///
/// Enqueuing is synchronous and happens on the backend's main actor.  A
/// single consumer task then awaits every send in FIFO order.  Multi-frame
/// batches remain contiguous, which is important for synthetic taps and
/// Caps Lock's minimum hold time.
@MainActor
final class ReliableHIDQueue {
    struct Batch: Sendable {
        let messages: [HIDRPCMessage]
        let interMessageDelay: Duration?
    }

    typealias Sender = @Sendable (HIDRPCMessage) async -> Void

    private let continuation: AsyncStream<Batch>.Continuation
    private let consumer: Task<Void, Never>

    init(send: @escaping Sender) {
        let (stream, continuation) = AsyncStream.makeStream(of: Batch.self)
        self.continuation = continuation
        self.consumer = Task {
            for await batch in stream {
                for (index, message) in batch.messages.enumerated() {
                    guard !Task.isCancelled else { return }
                    await send(message)
                    if index < batch.messages.count - 1,
                       let delay = batch.interMessageDelay {
                        do {
                            try await Task.sleep(for: delay)
                        } catch {
                            return
                        }
                    }
                }
            }
        }
    }

    func enqueue(_ message: HIDRPCMessage) {
        continuation.yield(Batch(messages: [message], interMessageDelay: nil))
    }

    /// Enqueue messages that must not be interleaved with a later keyboard
    /// event.  `interMessageDelay` is applied only between messages.
    func enqueueBatch(
        _ messages: [HIDRPCMessage],
        interMessageDelay: Duration? = nil
    ) {
        guard !messages.isEmpty else { return }
        continuation.yield(Batch(
            messages: messages,
            interMessageDelay: interMessageDelay
        ))
    }

    func cancel() {
        continuation.finish()
        consumer.cancel()
    }

    /// Test/support hook: finish accepting work and wait until all queued
    /// batches have been delivered.
    func finishAndWait() async {
        continuation.finish()
        await consumer.value
    }
}
