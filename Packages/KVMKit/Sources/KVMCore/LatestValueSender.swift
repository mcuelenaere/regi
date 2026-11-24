// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Gets a device into the latest wanted state when it handles each request
/// concurrently.
///
/// JetKVM firmware runs every JSON-RPC message in its own goroutine, so two
/// requests in flight can be applied in either order (a quick hide-then-show
/// could leave the video paused while the window is visible). `send` is
/// synchronous, and a single long-lived consumer awaits each call — which
/// itself waits for the device's reply — before starting the next. So at
/// most one call is ever in flight, and values that were never sent are
/// dropped in favour of the newest (`bufferingNewest(1)`): the last value
/// handed to `send` is always the last one the device sees.
///
/// Unlike `InputQueue` this is for state, not events: intermediate values
/// are intentionally lost. A failed call is not retried; the caller decides
/// (the JetKVM backend re-sends its latched state on reconnect).
@MainActor
public final class LatestValueSender<Value: Sendable> {
    private let continuation: AsyncStream<Value>.Continuation
    private let consumer: Task<Void, Never>

    public init(send: @escaping @Sendable (Value) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        consumer = Task {
            for await value in stream {
                guard !Task.isCancelled else { return }
                await send(value)
            }
        }
    }

    public func send(_ value: Value) {
        continuation.yield(value)
    }

    /// Drop anything not yet sent. Later `send` calls are ignored.
    public func cancel() {
        continuation.finish()
        consumer.cancel()
    }
}
