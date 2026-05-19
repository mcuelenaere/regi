import Foundation
import JetKVMProtocol
import OSLog
import WebRTC

private let log = Logger(subsystem: "app.regi.mac", category: "webrtc")

public enum WebRTCFacadeError: Error, Sendable {
    case peerConnectionCreationFailed
    case dataChannelCreationFailed(label: String)
    case offerCreationFailed(String)
    case sessionDescriptionCodecFailure(String)
    case setLocalDescriptionFailed(String)
    case setRemoteDescriptionFailed(String)
    case addIceCandidateFailed(String)
    case alreadyStarted
    case notStarted
}

/// Which transport channel an outgoing HID-RPC message should ride on.
/// Per `BRIEFING.md`: keyboard reports + handshake go reliable, pointer
/// and mouse reports go unreliable-ordered (under congestion, dropping
/// stale absolute coords is better than queueing).
public enum HIDChannel: Sendable {
    case reliable          // "hidrpc"
    case unreliableOrdered // "hidrpc-unreliable-ordered"
}

/// High-level connection state surfaced to the UI / Session actor. Wraps the
/// raw WebRTC states into a smaller vocabulary the rest of the app can
/// reason about.
public enum WebRTCConnectionState: Sendable, Equatable {
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

/// Wraps WebRTC.framework's RTCPeerConnection. The rest of the app should
/// not import WebRTC; route all interaction through this facade so version
/// upgrades stay localised (per the plan's risk #2).
///
/// Lifecycle for M1: `start()` creates the peer connection with one
/// recvonly video transceiver, builds an offer SDP and returns its
/// base64-encoded JSON form. The Session actor sends that on the signaling
/// WS, gets back an answer, and calls `setRemoteAnswer(...)`. ICE flows in
/// both directions via `addRemoteIceCandidate(...)` and the
/// `localIceCandidates` stream.
public actor WebRTCFacade {
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var delegate: PeerDelegate?
    private var hidrpcReliable: RTCDataChannel?
    private var hidrpcUnreliableOrdered: RTCDataChannel?
    private var hidDataChannelDelegate: HIDDataChannelDelegate?
    private var rpcChannel: RTCDataChannel?
    private var rpcDelegate: RPCDataChannelDelegate?
    private var hostBridgeChannel: RTCDataChannel?
    private var hostBridgeDelegate: HostBridgeDataChannelDelegate?

    public let localIceCandidates: AsyncStream<IceCandidate>
    public let videoTracks: AsyncStream<RTCVideoTrack>
    public let connectionState: AsyncStream<WebRTCConnectionState>
    /// Stream of incoming HID-RPC messages from the device (LED state,
    /// keydown state, macro state, …). Only the reliable channel
    /// realistically receives — server-pushed updates are all on
    /// `hidrpc`.
    public let incomingHID: AsyncStream<HIDRPCMessage>
    /// Reflects the open/closed state of the reliable `hidrpc` channel.
    /// `true` means we've sent the handshake and the channel is ready to
    /// carry input.
    public let hidReadyState: AsyncStream<Bool>
    /// Raw text frames received on the `rpc` data channel. The
    /// JSONRPCClient parses these into requests / responses /
    /// notifications.
    public let incomingRPCFrames: AsyncStream<Data>
    /// Reflects the open/closed state of the `rpc` channel.
    public let rpcReadyState: AsyncStream<Bool>
    /// Raw binary frames received on the `host_bridge` data channel.
    /// JetKVM relays these from a host-side agent (clipboard sync etc.)
    /// unchanged; consumers parse them as agent-protocol `Envelope`s.
    public let incomingHostBridgeFrames: AsyncStream<Data>
    /// Reflects the open/closed state of the `host_bridge` channel.
    public let hostBridgeReadyState: AsyncStream<Bool>
    /// Connection-quality samples produced by the stats poller every
    /// ~1 second once the peer connection is up.
    public let stats: AsyncStream<ConnectionStats>

    private let localIceCandidatesContinuation: AsyncStream<IceCandidate>.Continuation
    private let videoTracksContinuation: AsyncStream<RTCVideoTrack>.Continuation
    private let connectionStateContinuation: AsyncStream<WebRTCConnectionState>.Continuation
    private let incomingHIDContinuation: AsyncStream<HIDRPCMessage>.Continuation
    private let hidReadyStateContinuation: AsyncStream<Bool>.Continuation
    private let incomingRPCFramesContinuation: AsyncStream<Data>.Continuation
    private let rpcReadyStateContinuation: AsyncStream<Bool>.Continuation
    private let incomingHostBridgeFramesContinuation: AsyncStream<Data>.Continuation
    private let hostBridgeReadyStateContinuation: AsyncStream<Bool>.Continuation
    private let statsContinuation: AsyncStream<ConnectionStats>.Continuation
    private var statsTask: Task<Void, Never>?

    public init() {
        // RTCDefaultVideoEncoderFactory / RTCDefaultVideoDecoderFactory ship
        // hardware-accelerated H.264 + H.265 decoders backed by VideoToolbox
        // on Apple platforms — that's what gets us hardware decode "for free".
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory,
            decoderFactory: videoDecoderFactory
        )

        var iceCont: AsyncStream<IceCandidate>.Continuation!
        self.localIceCandidates = AsyncStream<IceCandidate> { iceCont = $0 }
        self.localIceCandidatesContinuation = iceCont

        var trackCont: AsyncStream<RTCVideoTrack>.Continuation!
        self.videoTracks = AsyncStream<RTCVideoTrack> { trackCont = $0 }
        self.videoTracksContinuation = trackCont

        var stateCont: AsyncStream<WebRTCConnectionState>.Continuation!
        self.connectionState = AsyncStream<WebRTCConnectionState> { stateCont = $0 }
        self.connectionStateContinuation = stateCont

        var hidCont: AsyncStream<HIDRPCMessage>.Continuation!
        self.incomingHID = AsyncStream<HIDRPCMessage> { hidCont = $0 }
        self.incomingHIDContinuation = hidCont

        var readyCont: AsyncStream<Bool>.Continuation!
        self.hidReadyState = AsyncStream<Bool> { readyCont = $0 }
        self.hidReadyStateContinuation = readyCont

        var rpcFramesCont: AsyncStream<Data>.Continuation!
        self.incomingRPCFrames = AsyncStream<Data> { rpcFramesCont = $0 }
        self.incomingRPCFramesContinuation = rpcFramesCont

        var rpcReadyCont: AsyncStream<Bool>.Continuation!
        self.rpcReadyState = AsyncStream<Bool> { rpcReadyCont = $0 }
        self.rpcReadyStateContinuation = rpcReadyCont

        var hostBridgeFramesCont: AsyncStream<Data>.Continuation!
        self.incomingHostBridgeFrames = AsyncStream<Data> { hostBridgeFramesCont = $0 }
        self.incomingHostBridgeFramesContinuation = hostBridgeFramesCont

        var hostBridgeReadyCont: AsyncStream<Bool>.Continuation!
        self.hostBridgeReadyState = AsyncStream<Bool> { hostBridgeReadyCont = $0 }
        self.hostBridgeReadyStateContinuation = hostBridgeReadyCont

        var statsCont: AsyncStream<ConnectionStats>.Continuation!
        self.stats = AsyncStream<ConnectionStats> { statsCont = $0 }
        self.statsContinuation = statsCont
    }

    /// Create the peer connection, add a single recvonly video transceiver,
    /// and produce an offer. Returns the offer in the wire form expected by
    /// the JetKVM signaling protocol: `base64(JSON({type:"offer", sdp:...}))`.
    public func start(iceServers: [String] = []) async throws -> String {
        guard peerConnection == nil else { throw WebRTCFacadeError.alreadyStarted }

        let config = RTCConfiguration()
        config.iceServers = iceServers.isEmpty ? [] : [RTCIceServer(urlStrings: iceServers)]
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        let delegate = PeerDelegate(
            iceContinuation: localIceCandidatesContinuation,
            trackContinuation: videoTracksContinuation,
            stateContinuation: connectionStateContinuation
        )
        self.delegate = delegate

        guard let pc = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: delegate
        ) else {
            throw WebRTCFacadeError.peerConnectionCreationFailed
        }
        self.peerConnection = pc

        // Single recvonly video transceiver — server adds its track to it.
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .recvOnly
        _ = pc.addTransceiver(of: .video, init: transceiverInit)

        // Open the HID data channels BEFORE creating the offer so they
        // appear in the offer SDP. The server's dispatch is keyed on
        // channel label (`webrtc.go:382-414`); reliability options
        // matter only for client-side transport behaviour.
        let hidDelegate = HIDDataChannelDelegate(
            incomingContinuation: incomingHIDContinuation,
            readyStateContinuation: hidReadyStateContinuation
        )
        self.hidDataChannelDelegate = hidDelegate

        let reliableConfig = RTCDataChannelConfiguration()
        reliableConfig.isOrdered = true
        guard let reliable = pc.dataChannel(forLabel: "hidrpc", configuration: reliableConfig) else {
            throw WebRTCFacadeError.dataChannelCreationFailed(label: "hidrpc")
        }
        reliable.delegate = hidDelegate
        self.hidrpcReliable = reliable

        let unreliableConfig = RTCDataChannelConfiguration()
        unreliableConfig.isOrdered = true
        unreliableConfig.maxRetransmits = 0
        guard let unreliable = pc.dataChannel(
            forLabel: "hidrpc-unreliable-ordered",
            configuration: unreliableConfig
        ) else {
            throw WebRTCFacadeError.dataChannelCreationFailed(label: "hidrpc-unreliable-ordered")
        }
        unreliable.delegate = hidDelegate
        self.hidrpcUnreliableOrdered = unreliable

        // Open the `rpc` channel for JSON-RPC traffic. Ordered,
        // reliable, text-mode. Server-pushed events fire on this
        // channel as soon as it opens (`webrtc.go:406-411`) — the
        // JSONRPCClient consumer handles those notifications without
        // a separate subscribe.
        let rpcConfig = RTCDataChannelConfiguration()
        rpcConfig.isOrdered = true
        let rpcDelegate = RPCDataChannelDelegate(
            framesContinuation: incomingRPCFramesContinuation,
            readyStateContinuation: rpcReadyStateContinuation
        )
        self.rpcDelegate = rpcDelegate
        guard let rpc = pc.dataChannel(forLabel: "rpc", configuration: rpcConfig) else {
            throw WebRTCFacadeError.dataChannelCreationFailed(label: "rpc")
        }
        rpc.delegate = rpcDelegate
        self.rpcChannel = rpc

        // Open the `host_bridge` channel. Ordered + reliable: the agent
        // protocol uses raw deflate which can't recover from a dropped
        // frame, so retransmit is non-negotiable. The label and binary
        // framing are part of the JetKVM relay's contract — see the
        // firmware's internal/clipboard/ package.
        let hostBridgeConfig = RTCDataChannelConfiguration()
        hostBridgeConfig.isOrdered = true
        let hostBridgeDelegate = HostBridgeDataChannelDelegate(
            framesContinuation: incomingHostBridgeFramesContinuation,
            readyStateContinuation: hostBridgeReadyStateContinuation
        )
        self.hostBridgeDelegate = hostBridgeDelegate
        guard let hostBridge = pc.dataChannel(forLabel: "host_bridge", configuration: hostBridgeConfig) else {
            throw WebRTCFacadeError.dataChannelCreationFailed(label: "host_bridge")
        }
        hostBridge.delegate = hostBridgeDelegate
        self.hostBridgeChannel = hostBridge

        // Kick off the connection-quality stats poller. Runs at ~1 Hz
        // for the lifetime of the peer connection. First sample lands
        // ~1s after start; deltas (bitrate, decode time, playback
        // delay) are nil on that first sample because the parser has
        // no previous-value reference yet.
        statsTask = Task { [weak self] in
            await Self.runStatsPoller(
                peerConnection: pc,
                continuation: self?.statsContinuation
            )
        }

        // Create the offer.
        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveVideo": "true"],
            optionalConstraints: nil
        )
        let offer = try await Self.createOffer(pc: pc, constraints: offerConstraints)

        // Set local description to commit the offer.
        try await Self.setLocalDescription(pc: pc, sdp: offer)

        // Encode for the wire.
        return try Self.encodeSessionDescription(offer)
    }

    /// Apply the answer received from the server. The wire format is
    /// `base64(JSON({type:"answer", sdp:...}))`, same shape the offer uses.
    public func setRemoteAnswer(sdpBase64: String) async throws {
        guard let pc = peerConnection else { throw WebRTCFacadeError.notStarted }
        let answer = try Self.decodeSessionDescription(sdpBase64)
        try await Self.setRemoteDescription(pc: pc, sdp: answer)
    }

    /// Pass an ICE candidate received from the server into the peer
    /// connection.
    public func addRemoteIceCandidate(_ candidate: IceCandidate) async throws {
        guard let pc = peerConnection else { throw WebRTCFacadeError.notStarted }
        let rtcCandidate = RTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: Int32(candidate.sdpMLineIndex ?? 0),
            sdpMid: candidate.sdpMid
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.add(rtcCandidate) { error in
                if let error {
                    cont.resume(throwing: WebRTCFacadeError.addIceCandidateFailed(String(describing: error)))
                } else {
                    cont.resume()
                }
            }
        }
    }

    /// Send a HID-RPC message on the chosen channel. Best-effort — for
    /// the unreliable channel a dropped frame is the intended behaviour;
    /// for the reliable channel SCTP retransmits until the channel
    /// closes.
    public func sendHID(_ message: HIDRPCMessage, on channel: HIDChannel) {
        let target: RTCDataChannel?
        switch channel {
        case .reliable:          target = hidrpcReliable
        case .unreliableOrdered: target = hidrpcUnreliableOrdered
        }
        guard let target else { return }
        let buffer = RTCDataBuffer(data: message.wireFormat, isBinary: true)
        _ = target.sendData(buffer)
    }

    /// Send a UTF-8 text frame on the `rpc` data channel. Returns
    /// `false` if the channel isn't open or the send queued failed.
    /// Used by `JSONRPCClient` as its outgoing transport.
    public func sendRPCFrame(_ frame: String) -> Bool {
        guard let channel = rpcChannel else { return false }
        guard let bytes = frame.data(using: .utf8) else { return false }
        let buffer = RTCDataBuffer(data: bytes, isBinary: false)
        return channel.sendData(buffer)
    }

    /// Send one binary frame on the `host_bridge` data channel.
    /// Returns `false` if the channel isn't open or the underlying
    /// SCTP send queue rejected the buffer.
    public func sendHostBridge(_ data: Data) -> Bool {
        guard let channel = hostBridgeChannel else {
            log.debug("[WEBRTC] sendHostBridge: channel nil; dropping \(data.count, privacy: .public) bytes")
            return false
        }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        let ok = channel.sendData(buffer)
        log.debug("[WEBRTC] sendHostBridge: \(data.count, privacy: .public) bytes → \(ok ? "queued" : "rejected", privacy: .public)")
        return ok
    }

    public func close() async {
        statsTask?.cancel()
        statsTask = nil
        peerConnection?.close()
        peerConnection = nil
        delegate = nil
        hidrpcReliable = nil
        hidrpcUnreliableOrdered = nil
        hidDataChannelDelegate = nil
        rpcChannel = nil
        rpcDelegate = nil
        hostBridgeChannel = nil
        hostBridgeDelegate = nil
        localIceCandidatesContinuation.finish()
        videoTracksContinuation.finish()
        connectionStateContinuation.finish()
        incomingHIDContinuation.finish()
        hidReadyStateContinuation.finish()
        incomingRPCFramesContinuation.finish()
        rpcReadyStateContinuation.finish()
        incomingHostBridgeFramesContinuation.finish()
        hostBridgeReadyStateContinuation.finish()
        statsContinuation.finish()
    }

    // MARK: - SDP wire format

    /// JSON shape pion `webrtc.SessionDescription` serializes to. The
    /// JetKVM server base64-encodes this JSON for transport (`webrtc.go:206-211`).
    private struct SessionDescriptionJSON: Codable {
        let type: String
        let sdp: String
    }

    private static func encodeSessionDescription(_ sdp: RTCSessionDescription) throws -> String {
        let typeString: String
        switch sdp.type {
        case .offer: typeString = "offer"
        case .answer: typeString = "answer"
        case .prAnswer: typeString = "pranswer"
        case .rollback: typeString = "rollback"
        @unknown default:
            throw WebRTCFacadeError.sessionDescriptionCodecFailure("unknown sdp type")
        }
        let json = SessionDescriptionJSON(type: typeString, sdp: sdp.sdp)
        let data = try JSONEncoder().encode(json)
        return data.base64EncodedString()
    }

    private static func decodeSessionDescription(_ base64: String) throws -> RTCSessionDescription {
        guard let data = Data(base64Encoded: base64) else {
            throw WebRTCFacadeError.sessionDescriptionCodecFailure("invalid base64")
        }
        let json = try JSONDecoder().decode(SessionDescriptionJSON.self, from: data)
        let type: RTCSdpType
        switch json.type.lowercased() {
        case "offer": type = .offer
        case "answer": type = .answer
        case "pranswer": type = .prAnswer
        case "rollback": type = .rollback
        default:
            throw WebRTCFacadeError.sessionDescriptionCodecFailure("unknown sdp type: \(json.type)")
        }
        return RTCSessionDescription(type: type, sdp: json.sdp)
    }

    // MARK: - Async wrappers around RTCPeerConnection callbacks

    private static func createOffer(
        pc: RTCPeerConnection,
        constraints: RTCMediaConstraints
    ) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { cont in
            pc.offer(for: constraints) { sdp, error in
                if let error {
                    cont.resume(throwing: WebRTCFacadeError.offerCreationFailed(String(describing: error)))
                } else if let sdp {
                    cont.resume(returning: sdp)
                } else {
                    cont.resume(throwing: WebRTCFacadeError.offerCreationFailed("no sdp and no error"))
                }
            }
        }
    }

    private static func setLocalDescription(
        pc: RTCPeerConnection,
        sdp: RTCSessionDescription
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error {
                    cont.resume(throwing: WebRTCFacadeError.setLocalDescriptionFailed(String(describing: error)))
                } else {
                    cont.resume()
                }
            }
        }
    }

    private static func setRemoteDescription(
        pc: RTCPeerConnection,
        sdp: RTCSessionDescription
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error {
                    cont.resume(throwing: WebRTCFacadeError.setRemoteDescriptionFailed(String(describing: error)))
                } else {
                    cont.resume()
                }
            }
        }
    }

    /// Background loop that walks `RTCPeerConnection.statistics`
    /// every second and yields a `ConnectionStats` on the stream.
    /// Cancellation (via Task.cancel) ends the loop and finishes
    /// the stream from the close() path.
    private static func runStatsPoller(
        peerConnection: RTCPeerConnection,
        continuation: AsyncStream<ConnectionStats>.Continuation?
    ) async {
        guard let continuation else { return }
        var parser = WebRTCStatsParser()
        while !Task.isCancelled {
            let report: RTCStatisticsReport = await withCheckedContinuation { cont in
                peerConnection.statistics { report in
                    cont.resume(returning: report)
                }
            }
            let sample = parser.parse(report)
            continuation.yield(sample)
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// Bridges RTCPeerConnectionDelegate (called on WebRTC.framework's own
/// queue) to the actor's async streams. The continuations are Sendable and
/// thread-safe; no `await` needed in callbacks.
private final class PeerDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    let iceContinuation: AsyncStream<IceCandidate>.Continuation
    let trackContinuation: AsyncStream<RTCVideoTrack>.Continuation
    let stateContinuation: AsyncStream<WebRTCConnectionState>.Continuation

    init(
        iceContinuation: AsyncStream<IceCandidate>.Continuation,
        trackContinuation: AsyncStream<RTCVideoTrack>.Continuation,
        stateContinuation: AsyncStream<WebRTCConnectionState>.Continuation
    ) {
        self.iceContinuation = iceContinuation
        self.trackContinuation = trackContinuation
        self.stateContinuation = stateContinuation
    }

    // MARK: - Required delegate methods

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        // We don't currently surface signaling state — the offer/answer
        // flow is driven explicitly by the Session actor.
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        // Plan B legacy callback — Unified Plan uses didAdd:rtpReceiver:streams: instead.
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        // Plan B legacy callback.
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        // Renegotiation triggered (e.g. after addTransceiver). For our
        // M1 flow we drive negotiation explicitly so this is informational.
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let mapped: WebRTCConnectionState
        switch newState {
        case .new: mapped = .new
        case .checking, .count: mapped = .connecting
        case .connected, .completed: mapped = .connected
        case .disconnected: mapped = .disconnected
        case .failed: mapped = .failed
        case .closed: mapped = .closed
        @unknown default: mapped = .new
        }
        log.info("ICE state → \(String(describing: mapped), privacy: .public)")
        stateContinuation.yield(mapped)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        // Gathering state isn't surfaced — onLocalIceCandidate carries the data we need.
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let wire = IceCandidate(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: UInt16(max(0, candidate.sdpMLineIndex)),
            usernameFragment: nil
        )
        iceContinuation.yield(wire)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        // Removed candidates not surfaced.
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // Server-initiated data channels aren't expected in the JetKVM
        // protocol — the client opens all channels. Will be revisited in M2.
    }

    // MARK: - Unified Plan callbacks

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            trackContinuation.yield(track)
        }
    }
}

/// Delegate handling state and incoming messages for the HID data
/// channels. Both `hidrpc` and `hidrpc-unreliable-ordered` share this
/// instance.
///
/// Critical: when `hidrpc` opens, this delegate sends the HID-RPC
/// handshake (`[0x01, 0x01]`) **synchronously** inside the
/// `didChangeState` callback, before any `await` or `Task` switch.
/// The server gates `Session.hidRPCAvailable` on receiving this
/// handshake (`hidrpc.go:28`); any HID input sent before it lands is
/// silently dropped.
private final class HIDDataChannelDelegate: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    let incomingContinuation: AsyncStream<HIDRPCMessage>.Continuation
    let readyStateContinuation: AsyncStream<Bool>.Continuation

    init(
        incomingContinuation: AsyncStream<HIDRPCMessage>.Continuation,
        readyStateContinuation: AsyncStream<Bool>.Continuation
    ) {
        self.incomingContinuation = incomingContinuation
        self.readyStateContinuation = readyStateContinuation
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        log.info("HID channel \(dataChannel.label, privacy: .public) state=\(stateLabel(dataChannel.readyState), privacy: .public)")
        // Only the reliable channel triggers handshake + ready signal.
        // The unreliable channel is just a transport — when it opens it's
        // ready to ship pointer reports immediately, but the server still
        // requires the reliable handshake before acting on anything.
        guard dataChannel.label == "hidrpc" else { return }
        switch dataChannel.readyState {
        case .open:
            // Send handshake synchronously here. Don't `Task { ... }` it —
            // see class doc comment.
            let buffer = RTCDataBuffer(
                data: HIDRPCMessage.standardHandshake.wireFormat,
                isBinary: true
            )
            _ = dataChannel.sendData(buffer)
            readyStateContinuation.yield(true)
        case .closing, .closed:
            readyStateContinuation.yield(false)
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard buffer.isBinary else {
            log.error("HID channel \(dataChannel.label, privacy: .public) got non-binary frame; dropping")
            return
        }
        do {
            let message = try HIDRPCMessage(wireFormat: buffer.data)
            incomingContinuation.yield(message)
        } catch {
            // Drop unparseable frames — surfacing them as errors would
            // tear down the stream and there's nothing the caller can do.
            log.error("HID frame parse failed (\(buffer.data.count, privacy: .public) bytes): \(String(describing: error), privacy: .public)")
        }
    }
}

private func stateLabel(_ state: RTCDataChannelState) -> String {
    switch state {
    case .connecting: return "connecting"
    case .open: return "open"
    case .closing: return "closing"
    case .closed: return "closed"
    @unknown default: return "unknown(\(state.rawValue))"
    }
}

/// Delegate for the `rpc` text channel. Forwards raw frames to the
/// owning facade's stream; the JSONRPCClient does the parsing.
private final class RPCDataChannelDelegate: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    let framesContinuation: AsyncStream<Data>.Continuation
    let readyStateContinuation: AsyncStream<Bool>.Continuation

    init(
        framesContinuation: AsyncStream<Data>.Continuation,
        readyStateContinuation: AsyncStream<Bool>.Continuation
    ) {
        self.framesContinuation = framesContinuation
        self.readyStateContinuation = readyStateContinuation
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        log.info("rpc channel state=\(stateLabel(dataChannel.readyState), privacy: .public)")
        switch dataChannel.readyState {
        case .open: readyStateContinuation.yield(true)
        case .closing, .closed: readyStateContinuation.yield(false)
        case .connecting: break
        @unknown default: break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        // The rpc channel is text-mode; ignore any binary frames the
        // server might accidentally send.
        guard !buffer.isBinary else {
            log.error("rpc channel got binary frame; dropping")
            return
        }
        framesContinuation.yield(buffer.data)
    }
}

/// Delegate for the `host_bridge` data channel. Forwards raw binary
/// frames to the owning facade's stream; the consumer
/// (`ClipboardBridge`) parses them as agent-protocol `Envelope`s.
private final class HostBridgeDataChannelDelegate: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    let framesContinuation: AsyncStream<Data>.Continuation
    let readyStateContinuation: AsyncStream<Bool>.Continuation

    init(
        framesContinuation: AsyncStream<Data>.Continuation,
        readyStateContinuation: AsyncStream<Bool>.Continuation
    ) {
        self.framesContinuation = framesContinuation
        self.readyStateContinuation = readyStateContinuation
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        log.info("host_bridge channel state=\(stateLabel(dataChannel.readyState), privacy: .public)")
        switch dataChannel.readyState {
        case .open: readyStateContinuation.yield(true)
        case .closing, .closed: readyStateContinuation.yield(false)
        case .connecting: break
        @unknown default: break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        // The host_bridge channel is binary; ignore any text frames.
        guard buffer.isBinary else {
            log.error("host_bridge channel got text frame; dropping")
            return
        }
        log.debug("[WEBRTC] host_bridge inbound: \(buffer.data.count, privacy: .public) bytes")
        framesContinuation.yield(buffer.data)
    }
}
