import Foundation
import KVMCore
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "rpc")

public enum JSONRPCClientError: Error, Sendable {
    /// Underlying transport (rpc data channel) reported send failure.
    case sendFailed
    /// Server returned a `{"error": …}` response.
    case server(JSONRPCErrorObject)
    /// Response wasn't shaped like a JSON-RPC 2.0 response.
    case malformedResponse(String)
    /// Pending call was cancelled because the client was closed.
    case channelClosed
    /// Tried to encode params that don't UTF-8 round-trip.
    case encoding(String)
}

// Decoded shapes for the response. These are file-private rather
// than nested inside `call(...)` because Swift forbids nested types
// in generic functions.

private struct ResponseHeader: Decodable {
    let id: Int
    let error: JSONRPCErrorObject?
}

private struct ResultEnvelope<R: Decodable>: Decodable {
    let result: R
}

private struct IncomingEnvelope: Decodable {
    let id: Int?
    let method: String?
}

/// JSON-RPC 2.0 client tied to a single bidirectional text channel
/// (here: the WebRTC `rpc` data channel).
///
/// `call(...)` sends a request and awaits the matching response by
/// `id`. Server-pushed events without an `id` are dispatched to the
/// `notifications` `AsyncStream` for the consumer to handle.
///
/// The client owns the request id space (incrementing from 1) and a
/// dictionary of pending continuations keyed by id. On `close()` every
/// outstanding continuation is resumed with `.channelClosed` so callers
/// don't hang forever after the channel drops.
public actor JSONRPCClient {
    /// Sends one text frame on the underlying channel. Returns `true`
    /// on success, `false` on failure (including channel-closed).
    public typealias TextFrameSender = @Sendable (String) async -> Bool

    public let notifications: AsyncStream<JSONRPCNotification>
    private let notificationsContinuation: AsyncStream<JSONRPCNotification>.Continuation

    private let send: TextFrameSender
    private var nextID: Int = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]

    private let encoder: JSONEncoder = JSONEncoder()
    private let decoder: JSONDecoder = JSONDecoder()

    public init(send: @escaping TextFrameSender) {
        self.send = send
        var cont: AsyncStream<JSONRPCNotification>.Continuation!
        self.notifications = AsyncStream<JSONRPCNotification> { cont = $0 }
        self.notificationsContinuation = cont
    }

    /// Send a request and decode the typed result.
    ///
    /// `params` defaults to `EmptyParams()` (encodes to `{}`) which is
    /// what JetKVM's gin handlers expect for parameter-less methods.
    public func call<R: Decodable & Sendable>(
        method: String,
        params: some Encodable & Sendable = EmptyParams()
    ) async throws -> R {
        let id = nextID
        nextID += 1

        let request = JSONRPCRequest(method: method, params: params, id: id)
        let requestData: Data
        do {
            requestData = try encoder.encode(request)
        } catch {
            throw JSONRPCClientError.encoding(String(describing: error))
        }
        guard let frame = String(data: requestData, encoding: .utf8) else {
            throw JSONRPCClientError.encoding("UTF-8 round-trip failed")
        }

        // Capture the response Data via continuation; the channel
        // delegate will look up `id` and resume us when the matching
        // response arrives.
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [send] in
                let ok = await send(frame)
                if !ok {
                    log.error("rpc send failed for \(method, privacy: .public) id=\(id, privacy: .public)")
                    // Send failed; clean up so we don't leak the
                    // continuation (handle() won't ever resume it).
                    if let pending = await self.takePending(id) {
                        pending.resume(throwing: JSONRPCClientError.sendFailed)
                    }
                }
            }
        }

        // Decode in two passes so we can handle the error case before
        // forcing the result type to decode.
        let header: ResponseHeader
        do {
            header = try decoder.decode(ResponseHeader.self, from: responseData)
        } catch {
            log.error("rpc response header decode failed for \(method, privacy: .public) id=\(id, privacy: .public): \(String(describing: error), privacy: .public)")
            throw JSONRPCClientError.malformedResponse(String(describing: error))
        }
        if let serverError = header.error {
            log.notice("rpc server error for \(method, privacy: .public) id=\(id, privacy: .public): \(serverError.code, privacy: .public) \(serverError.message, privacy: .public)")
            throw JSONRPCClientError.server(serverError)
        }
        // For void-result calls (R == VoidValue) skip the result
        // decode entirely. JetKVM's response for void methods is
        // `{"jsonrpc":"2.0","id":N}` with no `result` key — decoding
        // ResultEnvelope<VoidValue> would fail on the missing key.
        // Type-equality guarded so the as! is safe.
        if R.self == VoidValue.self {
            return VoidValue() as! R
        }
        do {
            let envelope = try decoder.decode(ResultEnvelope<R>.self, from: responseData)
            return envelope.result
        } catch {
            log.error("rpc result decode failed for \(method, privacy: .public) id=\(id, privacy: .public) as \(String(describing: R.self), privacy: .public): \(String(describing: error), privacy: .public)")
            throw JSONRPCClientError.malformedResponse(String(describing: error))
        }
    }

    /// Called by the rpc channel handler for each incoming text frame.
    /// Synchronously dispatches to a pending continuation (response)
    /// or yields to the notifications stream.
    public func handle(incomingFrame data: Data) {
        let envelope: IncomingEnvelope
        do {
            envelope = try decoder.decode(IncomingEnvelope.self, from: data)
        } catch {
            // Malformed frame — drop. Surfacing as an error would
            // tear down the notifications stream and there's nothing
            // the consumer can do.
            let preview = String(data: data.prefix(256), encoding: .utf8) ?? "<\(data.count) bytes non-UTF8>"
            log.error("rpc dropped malformed incoming frame: \(preview, privacy: .public)")
            return
        }
        if let id = envelope.id {
            if let continuation = pending.removeValue(forKey: id) {
                continuation.resume(returning: data)
            }
        } else if let method = envelope.method {
            let paramsData = extractParams(from: data)
            notificationsContinuation.yield(
                JSONRPCNotification(method: method, paramsData: paramsData)
            )
        }
    }

    /// Resume every outstanding call with `.channelClosed`. Idempotent.
    public func close() {
        for (_, continuation) in pending {
            continuation.resume(throwing: JSONRPCClientError.channelClosed)
        }
        pending.removeAll()
        notificationsContinuation.finish()
    }

    private func takePending(_ id: Int) -> CheckedContinuation<Data, Error>? {
        pending.removeValue(forKey: id)
    }

    private func extractParams(from data: Data) -> Data? {
        // We re-serialize via JSONSerialization so we can hand the
        // consumer raw `params` bytes without committing to a decode
        // type at dispatch time.
        guard let json = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? [String: Any],
            let params = json["params"]
        else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: params,
            options: [.fragmentsAllowed]
        )
    }
}
