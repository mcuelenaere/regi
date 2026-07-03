import Foundation
import SwiftProtobuf

/// Short, in-tree names for the generated proto types. Callers can
/// write `Hello`, `ClipboardOfferV1`, etc. without dragging the
/// `Jetkvm_Agent_V1_` prefix through call sites.
public typealias Envelope = Jetkvm_Agent_V1_Envelope
public typealias Hello = Jetkvm_Agent_V1_Hello
public typealias ClipboardOfferV1 = Jetkvm_Agent_V1_ClipboardOfferV1
public typealias ClipboardRequestV1 = Jetkvm_Agent_V1_ClipboardRequestV1
public typealias ClipboardResponseV1 = Jetkvm_Agent_V1_ClipboardResponseV1
public typealias Compression = Jetkvm_Agent_V1_Compression
public typealias Feature = Jetkvm_Agent_V1_Feature

public enum ClipboardCodecError: Swift.Error, Equatable {
    /// `Envelope.version` was anything other than `wireVersion`.
    case unsupportedVersion(UInt32)
    /// `Envelope.message` oneof was unset on the wire.
    case missingMessage
}

/// One agent ↔ client wire message, with the Envelope's oneof already
/// unwrapped so consumers can `switch` directly.
public enum AgentMessage: Sendable, Equatable {
    case hello(Hello)
    case offer(ClipboardOfferV1)
    case request(ClipboardRequestV1)
    case response(ClipboardResponseV1)
}

/// Encode / decode helpers for one frame of the agent ↔ client wire
/// protocol. Each WebSocket binary frame relayed via JetKVM's
/// `host_bridge` data channel is one serialized `Envelope`; this type
/// is the only place in the codebase that knows that.
public enum ClipboardCodec {
    /// Wire protocol version this codec implements. Receivers reject
    /// any envelope whose `version` doesn't match.
    public static let wireVersion: UInt32 = 1

    /// Decode one binary frame. Throws `.unsupportedVersion` for a
    /// version-mismatched envelope so callers can close the connection
    /// with a protocol error rather than mis-decode. Throws
    /// `.missingMessage` when the oneof is unset.
    public static func decode(_ data: Data) throws -> AgentMessage {
        let envelope = try Envelope(serializedBytes: data)
        guard envelope.version == wireVersion else {
            throw ClipboardCodecError.unsupportedVersion(envelope.version)
        }
        switch envelope.message {
        case .hello(let h): return .hello(h)
        case .offer(let o): return .offer(o)
        case .request(let r): return .request(r)
        case .response(let r): return .response(r)
        case .none:
            throw ClipboardCodecError.missingMessage
        }
    }

    /// Encode one message as a frame. Sets `Envelope.version` to the
    /// codec's `wireVersion`.
    public static func encode(_ message: AgentMessage) throws -> Data {
        var envelope = Envelope()
        envelope.version = wireVersion
        switch message {
        case .hello(let h): envelope.message = .hello(h)
        case .offer(let o): envelope.message = .offer(o)
        case .request(let r): envelope.message = .request(r)
        case .response(let r): envelope.message = .response(r)
        }
        return try envelope.serializedBytes()
    }

    // MARK: - Convenience constructors

    public static func encodeHello(
        compressions: [Compression],
        features: [Feature]
    ) throws -> Data {
        var hello = Hello()
        hello.protocolVersion = wireVersion
        hello.compressions = compressions
        hello.supportedFeatures = features
        return try encode(.hello(hello))
    }

    public static func encodeOffer(_ offer: ClipboardOfferV1) throws -> Data {
        try encode(.offer(offer))
    }

    public static func encodeRequest(offerId: UInt32, mime: String) throws -> Data {
        var req = ClipboardRequestV1()
        req.offerID = offerId
        req.mime = mime
        return try encode(.request(req))
    }

    public static func encodeResponse(_ response: ClipboardResponseV1) throws -> Data {
        try encode(.response(response))
    }
}
