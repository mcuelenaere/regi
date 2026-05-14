import Foundation

/// One frame on the WebRTC signaling WebSocket
/// (`/webrtc/signaling/client` for local, similar shape for cloud).
///
/// Wire format is JSON `{"type": <string>, "data": <varies>}`. Note the
/// asymmetry between offer and answer: the offer wraps the SDP base64 in
/// `{"sd": <base64>}`, but the answer carries the raw base64 string directly
/// in `data`. Verified at `web.go:317`, `web.go:452`, `cloud.go:471`,
/// `cloud.go:492` and `webrtc.go:155-211`.
public enum SignalingMessage: Sendable, Equatable {
    /// Server → client, sent immediately on WebSocket open.
    /// Empty `deviceVersion` indicates legacy firmware — treat as fatal.
    case deviceMetadata(DeviceMetadata)

    /// Client → server. The SDP is JSON-encoded, then base64-encoded.
    case offer(sdpBase64: String)

    /// Server → client. Same encoding as offer (JSON then base64).
    case answer(sdpBase64: String)

    /// Both directions. The candidate shape mirrors WebRTC's
    /// `RTCIceCandidateInit` (pion's `webrtc.ICECandidateInit`).
    case newIceCandidate(IceCandidate)
}

/// Initial server→client message.
public struct DeviceMetadata: Codable, Sendable, Equatable {
    public let deviceVersion: String
    /// HID-RPC opcodes the firmware actually dispatches on the binary
    /// channel. `nil` on older firmware that doesn't advertise the
    /// field — callers should fall back to the JSON-RPC path for any
    /// opcode that isn't in this set. Wire shape is `[]byte` server-
    /// side, which Go's `encoding/json` serializes as a base64 string.
    public let supportedHIDRPCOpcodes: Set<UInt8>?

    public init(deviceVersion: String, supportedHIDRPCOpcodes: Set<UInt8>? = nil) {
        self.deviceVersion = deviceVersion
        self.supportedHIDRPCOpcodes = supportedHIDRPCOpcodes
    }

    private enum CodingKeys: String, CodingKey {
        case deviceVersion
        case supportedHIDRPCOpcodes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.deviceVersion = try container.decode(String.self, forKey: .deviceVersion)
        if let base64 = try container.decodeIfPresent(String.self, forKey: .supportedHIDRPCOpcodes),
           let bytes = Data(base64Encoded: base64) {
            self.supportedHIDRPCOpcodes = Set(bytes)
        } else {
            self.supportedHIDRPCOpcodes = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceVersion, forKey: .deviceVersion)
        if let opcodes = supportedHIDRPCOpcodes {
            // Match the firmware's wire shape so round-trip tests pass:
            // []byte → base64 string.
            let data = Data(opcodes.sorted())
            try container.encode(data.base64EncodedString(), forKey: .supportedHIDRPCOpcodes)
        }
    }
}

/// `RTCIceCandidateInit` shape, matching pion `webrtc.ICECandidateInit`.
/// Optional fields use `omitempty` server-side.
public struct IceCandidate: Codable, Sendable, Equatable {
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: UInt16?
    public let usernameFragment: String?

    public init(
        candidate: String,
        sdpMid: String? = nil,
        sdpMLineIndex: UInt16? = nil,
        usernameFragment: String? = nil
    ) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.usernameFragment = usernameFragment
    }
}

extension SignalingMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    /// Inner shape of an offer's `data` field. Asymmetric with the answer.
    private struct OfferData: Codable {
        let sd: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "device-metadata":
            let metadata = try container.decode(DeviceMetadata.self, forKey: .data)
            self = .deviceMetadata(metadata)
        case "answer":
            // Raw base64 string directly in `data` — see `cloud.go:492`.
            let sdpBase64 = try container.decode(String.self, forKey: .data)
            self = .answer(sdpBase64: sdpBase64)
        case "offer":
            // The offer goes client→server but accept the symmetric form
            // here for round-trip testing and any future server-initiated use.
            let offer = try container.decode(OfferData.self, forKey: .data)
            self = .offer(sdpBase64: offer.sd)
        case "new-ice-candidate":
            let candidate = try container.decode(IceCandidate.self, forKey: .data)
            self = .newIceCandidate(candidate)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown signaling message type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .deviceMetadata(let meta):
            try container.encode("device-metadata", forKey: .type)
            try container.encode(meta, forKey: .data)
        case .offer(let sdp):
            try container.encode("offer", forKey: .type)
            try container.encode(OfferData(sd: sdp), forKey: .data)
        case .answer(let sdp):
            try container.encode("answer", forKey: .type)
            try container.encode(sdp, forKey: .data)
        case .newIceCandidate(let cand):
            try container.encode("new-ice-candidate", forKey: .type)
            try container.encode(cand, forKey: .data)
        }
    }
}
