import Foundation

/// `RTCIceCandidateInit` shape, matching pion `webrtc.ICECandidateInit`.
/// Optional fields use `omitempty` server-side. Shared WebRTC signaling
/// vocabulary: JetKVM's `SignalingMessage` carries it and both the JetKVM and
/// PiKVM backends feed it to `WebRTCFacade`.
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
