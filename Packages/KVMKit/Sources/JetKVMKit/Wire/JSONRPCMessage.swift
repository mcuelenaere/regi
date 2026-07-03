import Foundation

/// Wire types for the JSON-RPC 2.0 protocol JetKVM uses on the `rpc`
/// data channel (`jsonrpc.go:1243`).
///
/// Three message shapes share the wire:
/// - **Request** (us → device): `{"jsonrpc":"2.0", "method":..., "params":..., "id":...}`
/// - **Response** (device → us): `{"jsonrpc":"2.0", "id":..., "result":...}` or
///   `{"jsonrpc":"2.0", "id":..., "error":{...}}`
/// - **Notification** (device → us, no `id`): `{"jsonrpc":"2.0", "method":..., "params":...}`
///
/// The `id` field on requests/responses correlates a response to the
/// request that produced it; matching is the JSONRPCClient's job.

/// Outgoing request envelope.
public struct JSONRPCRequest<P: Encodable & Sendable>: Encodable, Sendable {
    public let jsonrpc: String
    public let method: String
    public let params: P
    public let id: Int

    public init(method: String, params: P, id: Int) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
        self.id = id
    }
}

/// Sentinel struct for methods that take no params. Encodes to `{}`.
public struct EmptyParams: Encodable, Sendable {
    public init() {}
}

/// Sentinel for methods whose response is `"result": null`. Custom
/// `Decodable` accepts any single value (including null) without
/// failing — that's what makes it usable as the return type of
/// `JSONRPCClient.notify` etc.
public struct VoidValue: Decodable, Sendable {
    public init() {}
    public init(from decoder: Decoder) throws {
        // Accept whatever the wire has. We don't read it.
    }
}

/// Server's error object inside a failed response.
public struct JSONRPCErrorObject: Codable, Sendable, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

/// Server-pushed event without a request id (`web.go:317-322` and
/// `webrtc.go:406-411` enumerate the ones JetKVM emits).
///
/// `paramsData` carries the raw JSON bytes of the `params` field so
/// the consumer can decode them with the type appropriate for the
/// specific `method`. nil if the notification had no params.
public struct JSONRPCNotification: Sendable, Equatable {
    public let method: String
    public let paramsData: Data?

    public init(method: String, paramsData: Data?) {
        self.method = method
        self.paramsData = paramsData
    }

    /// Decode the params field as a specific type. Throws if no
    /// params were present, or if decoding fails.
    public func decodeParams<P: Decodable>(_ type: P.Type) throws -> P {
        guard let paramsData else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "notification has no params field"
            ))
        }
        return try JSONDecoder().decode(P.self, from: paramsData)
    }
}
