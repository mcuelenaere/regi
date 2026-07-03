import Foundation

/// One sample of the WebRTC connection's runtime metrics. Built once
/// per stats poll (~1 Hz). The `WebRTCStatsParser` extracts these
/// from the W3C `getStats()` report; `Session` keeps a ring buffer
/// of recent samples for sparklines.
///
/// Time-derivative fields (bitrate, decode time, playback delay) are
/// `nil` on the very first sample because they need a previous-value
/// reference to compute deltas.
public struct ConnectionStats: Sendable, Equatable {
    /// Wall-clock at which this sample was produced. Drives the X
    /// axis of any sparkline rendering.
    public let timestamp: Date

    // MARK: - Network

    /// Selected ICE candidate-pair round-trip-time, milliseconds.
    /// nil when WebRTC hasn't yet measured RTT.
    public let roundTripTimeMs: Double?

    /// EWMA of inter-arrival jitter on the inbound RTP stream,
    /// milliseconds.
    public let jitterMs: Double?

    /// Inbound RTP packets the receiver has acknowledged getting.
    public let packetsReceived: Int64

    /// Inbound RTP packets reported lost. Loss percentage is
    /// `packetsLost / (packetsLost + packetsReceived) * 100`.
    public let packetsLost: Int64

    /// Bandwidth on the receive path right now, in bits per second.
    /// Computed as a delta from the previous sample's
    /// `bytesReceivedTotal`. nil on the first sample.
    public let bitrateBitsPerSecond: Double?

    /// "host" (LAN), "srflx" (NAT-traversed), "prflx" (peer
    /// reflexive), "relay" (TURN), or nil if no candidate pair is
    /// nominated yet.
    public let connectionType: ConnectionType?

    // MARK: - Video

    /// Decoded-frames-per-second from the inbound-rtp stat.
    public let framesPerSecond: Double

    /// Frames the network reported as received but the decode
    /// pipeline didn't finish.
    public let framesDropped: Int64

    /// Negotiated codec (e.g. "video/H264", "video/H265"). nil if
    /// the codec stat hasn't surfaced yet.
    public let codec: String?

    /// Number of distinct freeze events the player has noticed.
    /// (Frame inter-arrival > 150ms, per the W3C spec.)
    public let freezeCount: Int64

    /// Total wall-clock the video has been frozen, in seconds.
    /// Cumulative across the session.
    public let totalFreezesDurationSec: Double

    /// Average decode time per frame within this sample's interval,
    /// milliseconds. nil on first sample.
    public let decodeTimePerFrameMs: Double?

    // MARK: - Latency

    /// Average jitter-buffer delay per emitted frame within this
    /// sample's interval, milliseconds. nil on first sample.
    public let playbackDelayMs: Double?

    /// Composite input-latency estimate — the lower bound on what
    /// the user feels between moving the mouse and seeing the host
    /// respond: full RTT (input round-trips client → JetKVM → host
    /// → frame back → client) plus jitter-buffer delay plus decode
    /// time. Doesn't account for the host's display refresh,
    /// JetKVM's HDMI capture, or its encode time — those aren't
    /// exposed to us, so the real number is somewhere ~30-50 ms
    /// higher. Surfaced in the UI as "Input latency". nil if any
    /// measurable component is missing.
    public let endToEndLatencyMs: Double?

    // MARK: - Session totals

    /// Cumulative bytes received over this session, including RTP
    /// header overhead. Drive a "MB used this session" counter.
    public let bytesReceivedTotal: Int64

    public init(
        timestamp: Date,
        roundTripTimeMs: Double?,
        jitterMs: Double?,
        packetsReceived: Int64,
        packetsLost: Int64,
        bitrateBitsPerSecond: Double?,
        connectionType: ConnectionType?,
        framesPerSecond: Double,
        framesDropped: Int64,
        codec: String?,
        freezeCount: Int64,
        totalFreezesDurationSec: Double,
        decodeTimePerFrameMs: Double?,
        playbackDelayMs: Double?,
        endToEndLatencyMs: Double?,
        bytesReceivedTotal: Int64
    ) {
        self.timestamp = timestamp
        self.roundTripTimeMs = roundTripTimeMs
        self.jitterMs = jitterMs
        self.packetsReceived = packetsReceived
        self.packetsLost = packetsLost
        self.bitrateBitsPerSecond = bitrateBitsPerSecond
        self.connectionType = connectionType
        self.framesPerSecond = framesPerSecond
        self.framesDropped = framesDropped
        self.codec = codec
        self.freezeCount = freezeCount
        self.totalFreezesDurationSec = totalFreezesDurationSec
        self.decodeTimePerFrameMs = decodeTimePerFrameMs
        self.playbackDelayMs = playbackDelayMs
        self.endToEndLatencyMs = endToEndLatencyMs
        self.bytesReceivedTotal = bytesReceivedTotal
    }

    /// Loss percentage in 0..100 range, or nil if zero packets
    /// received (would divide by zero).
    public var packetLossPercent: Double? {
        let total = packetsReceived + packetsLost
        guard total > 0 else { return nil }
        return Double(packetsLost) / Double(total) * 100
    }
}

/// Where the active ICE candidate-pair sits on the network. Maps to
/// the W3C `RTCIceCandidateType` enum.
public enum ConnectionType: String, Sendable, Equatable {
    /// Local LAN — direct connection.
    case host
    /// Server reflexive — direct UDP via STUN-discovered address.
    case srflx
    /// Peer reflexive — direct UDP via address learned from peer.
    case prflx
    /// TURN relay — traffic round-trips through a relay server.
    case relay
}
