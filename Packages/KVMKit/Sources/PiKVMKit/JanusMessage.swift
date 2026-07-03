import Foundation

/// Wire codec for PiKVM's Janus WebSocket signaling (the `janus-protocol`
/// subprotocol at `/janus/ws`). Covers just the subset the µStreamer
/// streaming plugin needs: create session → attach
/// `janus.plugin.ustreamer` → `watch` → receive the server's JSEP offer
/// → answer via `start` → trickle ICE → keepalive.
///
/// Reference: the kvmd web client (`web/share/js/kvm/stream_janus.js`)
/// and the upstream Janus WebSocket API. The server creates the offer
/// and the client answers — the reverse of JetKVM.

/// A JSEP session description as Janus carries it (plain SDP, *not*
/// JetKVM's base64-wrapped form).
public struct JanusJSEP: Codable, Equatable, Sendable {
    public let type: String   // "offer" (in) / "answer" (out)
    public let sdp: String

    public init(type: String, sdp: String) {
        self.type = type
        self.sdp = sdp
    }
}

/// A trickle ICE candidate. `completed == true` signals end-of-candidates
/// (sent with the other fields nil).
public struct JanusCandidate: Codable, Equatable, Sendable {
    public let candidate: String?
    public let sdpMid: String?
    public let sdpMLineIndex: Int32?
    public let completed: Bool?

    public init(
        candidate: String? = nil,
        sdpMid: String? = nil,
        sdpMLineIndex: Int32? = nil,
        completed: Bool? = nil
    ) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.completed = completed
    }

    /// The end-of-candidates sentinel Janus expects.
    public static let completedSentinel = JanusCandidate(completed: true)
}

/// Builders for outbound Janus frames (client → server). Each returns
/// UTF-8 JSON ready to send on the WebSocket. Optional fields are
/// omitted from the JSON when nil (synthesized `encodeIfPresent`).
public enum JanusMessage {
    public static let uStreamerPlugin = "janus.plugin.ustreamer"

    private struct Outbound: Encodable {
        let janus: String
        let transaction: String
        var sessionId: UInt64?
        var handleId: UInt64?
        var plugin: String?
        var body: Body?
        var jsep: JanusJSEP?
        var candidate: JanusCandidate?

        struct Body: Encodable {
            let request: String
            var params: Params?

            struct Params: Encodable {
                var audio: Bool
            }
        }

        enum CodingKeys: String, CodingKey {
            case janus, transaction
            case sessionId = "session_id"
            case handleId = "handle_id"
            case plugin, body, jsep, candidate
        }
    }

    private static func encode(_ value: Outbound) throws -> Data {
        try JSONEncoder().encode(value)
    }

    /// `{"janus":"create","transaction":tx}`
    public static func create(transaction: String) throws -> Data {
        try encode(Outbound(janus: "create", transaction: transaction))
    }

    /// `{"janus":"attach","plugin":...,"session_id":sid,"transaction":tx}`
    public static func attach(
        sessionId: UInt64,
        plugin: String = uStreamerPlugin,
        transaction: String
    ) throws -> Data {
        var msg = Outbound(janus: "attach", transaction: transaction)
        msg.sessionId = sessionId
        msg.plugin = plugin
        return try encode(msg)
    }

    /// `{"janus":"message",...,"body":{"request":"watch","params":{"audio":…}}}`
    public static func watch(
        sessionId: UInt64,
        handleId: UInt64,
        transaction: String,
        audio: Bool = false
    ) throws -> Data {
        var msg = Outbound(janus: "message", transaction: transaction)
        msg.sessionId = sessionId
        msg.handleId = handleId
        msg.body = .init(request: "watch", params: .init(audio: audio))
        return try encode(msg)
    }

    /// `{"janus":"message",...,"body":{"request":"start"},"jsep":{type:"answer",sdp}}`
    public static func startAnswer(
        sessionId: UInt64,
        handleId: UInt64,
        transaction: String,
        answerSDP: String
    ) throws -> Data {
        var msg = Outbound(janus: "message", transaction: transaction)
        msg.sessionId = sessionId
        msg.handleId = handleId
        msg.body = .init(request: "start", params: nil)
        msg.jsep = JanusJSEP(type: "answer", sdp: answerSDP)
        return try encode(msg)
    }

    /// `{"janus":"trickle",...,"candidate":{...}}`
    public static func trickle(
        sessionId: UInt64,
        handleId: UInt64,
        transaction: String,
        candidate: JanusCandidate
    ) throws -> Data {
        var msg = Outbound(janus: "trickle", transaction: transaction)
        msg.sessionId = sessionId
        msg.handleId = handleId
        msg.candidate = candidate
        return try encode(msg)
    }

    /// `{"janus":"keepalive","session_id":sid,"transaction":tx}`
    public static func keepalive(sessionId: UInt64, transaction: String) throws -> Data {
        var msg = Outbound(janus: "keepalive", transaction: transaction)
        msg.sessionId = sessionId
        return try encode(msg)
    }
}

/// A decoded inbound Janus frame (server → client). The `janus` field is
/// the discriminator (`success`, `ack`, `event`, `error`, `webrtcup`,
/// `hangup`, `media`, `slowlink`, `timeout`, `keepalive`, …). Only the
/// fields the µStreamer flow needs are modelled; everything else is
/// ignored.
public struct JanusIncoming: Decodable, Sendable {
    public let janus: String
    public let transaction: String?
    /// Handle id for plugin events.
    public let sender: UInt64?
    public let sessionId: UInt64?
    /// Present on `success` — `data.id` is the new session or handle id.
    public let data: IDData?
    /// Present on plugin events that carry a (re)negotiation — the
    /// server's JSEP offer arrives here.
    public let jsep: JanusJSEP?
    public let plugindata: PluginData?
    public let error: JanusError?
    /// Present on inbound `trickle` frames — an ICE candidate the
    /// server gathered (or the end-of-candidates sentinel).
    public let candidate: JanusCandidate?

    public struct IDData: Decodable, Sendable {
        public let id: UInt64?
    }

    public struct PluginData: Decodable, Sendable {
        public let plugin: String?
        public let data: PluginResult?
    }

    /// The µStreamer plugin's `plugindata.data`. Surfaces error
    /// signalling (e.g. a `watch` issued before the stream is live);
    /// the rest of the payload is plugin status we don't need in v1.
    public struct PluginResult: Decodable, Sendable {
        public let error: String?
        public let errorCode: Int?

        enum CodingKeys: String, CodingKey {
            case error
            case errorCode = "error_code"
        }
    }

    public struct JanusError: Decodable, Sendable {
        public let code: Int?
        public let reason: String?
    }

    enum CodingKeys: String, CodingKey {
        case janus, transaction, sender, jsep, plugindata, error, data, candidate
        case sessionId = "session_id"
    }

    public static func decode(_ data: Data) throws -> JanusIncoming {
        try JSONDecoder().decode(JanusIncoming.self, from: data)
    }
}
