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

    public init(deviceVersion: String) {
        self.deviceVersion = deviceVersion
    }

    /// True iff `deviceVersion` parses as a dotted-numeric version
    /// (with an optional leading `v`) and is >= `minVersion`. Used to
    /// gate features by JetKVM firmware version when there's no
    /// runtime capability advertisement to lean on.
    ///
    /// Fail-closed: returns `false` if either side fails to parse, so
    /// an ambiguous version string leaves feature gates off rather
    /// than maybe-on.
    public func firmwareIsAtLeast(_ minVersion: String) -> Bool {
        guard let lhs = Self.parseVersion(deviceVersion),
              let rhs = Self.parseVersion(minVersion) else {
            return false
        }
        // Compare component-by-component, padding the shorter side
        // with zeros: "0.5" == "0.5.0" < "0.5.9".
        let maxLen = max(lhs.count, rhs.count)
        for i in 0..<maxLen {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return true
    }

    private static func parseVersion(_ s: String) -> [Int]? {
        let stripped = s.hasPrefix("v") ? String(s.dropFirst()) : s
        guard !stripped.isEmpty else { return nil }
        var result: [Int] = []
        for part in stripped.split(separator: ".") {
            guard let n = Int(part) else { return nil }
            result.append(n)
        }
        return result.isEmpty ? nil : result
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
