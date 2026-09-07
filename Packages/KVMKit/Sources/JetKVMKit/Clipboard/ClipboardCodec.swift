import Foundation
import SwiftProtobuf

/// Short, in-tree names for the generated proto types. Callers can
/// write `Hello`, `ClipboardOffer`, etc. without dragging the
/// `Tinypipe_V1_` prefix through call sites.
public typealias Envelope = Tinypipe_V1_Envelope
public typealias Hello = Tinypipe_V1_Hello
public typealias Payload = Tinypipe_V1_Payload
public typealias Representation = Tinypipe_V1_Representation
public typealias ClipboardOffer = Tinypipe_V1_ClipboardOffer
public typealias DragOffer = Tinypipe_V1_DragOffer
public typealias DragEnd = Tinypipe_V1_DragEnd
public typealias StreamOpen = Tinypipe_V1_StreamOpen
public typealias StreamData = Tinypipe_V1_StreamData
public typealias StreamClose = Tinypipe_V1_StreamClose
public typealias StreamCancel = Tinypipe_V1_StreamCancel
public typealias Compression = Tinypipe_V1_Compression
public typealias Feature = Tinypipe_V1_Feature

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
    case clipboardOffer(ClipboardOffer)
    case dragOffer(DragOffer)
    case dragEnd(DragEnd)
    case streamOpen(StreamOpen)
    case streamData(StreamData)
    case streamClose(StreamClose)
    case streamCancel(StreamCancel)
}

/// Encode / decode helpers for one frame of the tinypipe agent ↔ client
/// wire protocol. Each binary frame relayed via the KVM's `host_bridge`
/// data channel is one serialized `Envelope`; this type is the only
/// place in the codebase that knows that.
public enum ClipboardCodec {
    /// Wire protocol version this codec implements. Receivers reject
    /// any envelope whose `version` doesn't match.
    public static let wireVersion: UInt32 = 1

    /// Hard per-frame cap enforced by the relay: it forwards each frame
    /// as one WebRTC `host_bridge` send, and 64 KiB is the RFC 8841
    /// universal SCTP max-message-size. Anything larger must ride the
    /// streaming layer instead.
    public static let maxFrameBytes: Int = 64 * 1024

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
        case .hello(let m): return .hello(m)
        case .clipboardOffer(let m): return .clipboardOffer(m)
        case .dragOffer(let m): return .dragOffer(m)
        case .dragEnd(let m): return .dragEnd(m)
        case .streamOpen(let m): return .streamOpen(m)
        case .streamData(let m): return .streamData(m)
        case .streamClose(let m): return .streamClose(m)
        case .streamCancel(let m): return .streamCancel(m)
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
        case .hello(let m): envelope.message = .hello(m)
        case .clipboardOffer(let m): envelope.message = .clipboardOffer(m)
        case .dragOffer(let m): envelope.message = .dragOffer(m)
        case .dragEnd(let m): envelope.message = .dragEnd(m)
        case .streamOpen(let m): envelope.message = .streamOpen(m)
        case .streamData(let m): envelope.message = .streamData(m)
        case .streamClose(let m): envelope.message = .streamClose(m)
        case .streamCancel(let m): envelope.message = .streamCancel(m)
        }
        return try envelope.serializedBytes()
    }

    // MARK: - Convenience constructors

    public static func encodeHello(
        userAgent: String,
        compressions: [Compression],
        features: [Feature]
    ) throws -> Data {
        var hello = Hello()
        hello.userAgent = userAgent
        hello.supportedCompressions = compressions
        hello.supportedFeatures = features
        return try encode(.hello(hello))
    }

    public static func encodeClipboardOffer(_ offer: ClipboardOffer) throws -> Data {
        try encode(.clipboardOffer(offer))
    }

    /// A `StreamOpen` pulling one representation of a clipboard offer.
    /// The opener (the offer's *receiver*) allocates `streamId`.
    public static func encodeClipboardStreamOpen(
        streamId: UInt32,
        clipboardId: UInt32,
        index: UInt32
    ) throws -> Data {
        var item = StreamOpen.ClipboardItem()
        item.clipboardID = clipboardId
        item.index = index
        var open = StreamOpen()
        open.streamID = streamId
        open.source = .clipboardItem(item)
        return try encode(.streamOpen(open))
    }

    public static func encodeStreamData(streamId: UInt32, data: Data) throws -> Data {
        var frame = StreamData()
        frame.streamID = streamId
        frame.data = data
        return try encode(.streamData(frame))
    }

    public static func encodeStreamClose(
        streamId: UInt32,
        status: StreamClose.Status
    ) throws -> Data {
        var close = StreamClose()
        close.streamID = streamId
        close.status = status
        return try encode(.streamClose(close))
    }

    public static func encodeStreamCancel(streamId: UInt32) throws -> Data {
        var cancel = StreamCancel()
        cancel.streamID = streamId
        return try encode(.streamCancel(cancel))
    }
}
