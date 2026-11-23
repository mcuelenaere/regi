// SPDX-License-Identifier: AGPL-3.0-or-later

import KVMCore
import Foundation
import WebRTC

/// Walks an `RTCStatisticsReport` and produces a `ConnectionStats`.
///
/// Holds the previous sample's decode / jitter-buffer counters
/// internally so it can compute deltas (decode time per frame, playback
/// delay per frame) between calls, plus the last byte counts of every
/// data channel it has seen. Discard and
/// recreate on disconnect — those deltas are nonsense across a
/// reconnect.
struct WebRTCStatsParser {
    private var previousTotalDecodeTime: Double?
    private var previousFramesDecoded: Int64?
    private var previousJitterBufferDelay: Double?
    private var previousJitterBufferEmittedCount: Int64?
    /// Last byte counts per data-channel stat id. libwebrtc drops a
    /// channel's stats once it closes (an OS Services file drop's
    /// `guestfile_*` channel, say), so its bytes are kept here.
    private var dataChannels: [String: (category: TrafficCategory, bytes: ByteCounts)] = [:]

    init() {}

    mutating func parse(_ report: RTCStatisticsReport) -> ConnectionStats {
        let allStats = report.statistics

        // Find the inbound video RTP stream. There's one per remote
        // track; we only have one (the host's display).
        let videoInbound = allStats.values.first { stat in
            stat.type == "inbound-rtp" && (stat.values["kind"] as? String) == "video"
        }
        // Find the active ICE candidate-pair (state=succeeded + nominated).
        // Some stacks don't set `nominated` consistently; falling back to
        // any succeeded pair is fine in practice.
        let candidatePair = allStats.values.first { stat in
            stat.type == "candidate-pair"
                && (stat.values["state"] as? String) == "succeeded"
                && (stat.values["nominated"] as? NSNumber)?.boolValue == true
        } ?? allStats.values.first { stat in
            stat.type == "candidate-pair" && (stat.values["state"] as? String) == "succeeded"
        }
        // Look up the local candidate referenced by the active pair to
        // get the connection type (host/srflx/prflx/relay).
        let connectionType: ConnectionType? = {
            guard let localId = candidatePair?.values["localCandidateId"] as? String,
                  let local = allStats[localId],
                  local.type == "local-candidate",
                  let typeString = local.values["candidateType"] as? String
            else { return nil }
            return ConnectionType(rawValue: typeString)
        }()
        // Codec: the inbound-rtp references a codec id, that stats
        // object has the `mimeType`.
        let codec: String? = {
            guard let codecId = videoInbound?.values["codecId"] as? String,
                  let codecStat = allStats[codecId],
                  codecStat.type == "codec"
            else { return nil }
            return codecStat.values["mimeType"] as? String
        }()

        let v = videoInbound?.values ?? [:]
        let now = Date()

        // Counters from the inbound-rtp stat.
        let packetsReceived: Int64 = (v["packetsReceived"] as? NSNumber)?.int64Value ?? 0
        let packetsLost: Int64 = (v["packetsLost"] as? NSNumber)?.int64Value ?? 0
        let framesPerSecond: Double = (v["framesPerSecond"] as? NSNumber)?.doubleValue ?? 0
        let framesDecoded: Int64 = (v["framesDecoded"] as? NSNumber)?.int64Value ?? 0
        let jitterSeconds: Double? = (v["jitter"] as? NSNumber)?.doubleValue
        let totalDecodeTime: Double = (v["totalDecodeTime"] as? NSNumber)?.doubleValue ?? 0
        let jitterBufferDelay: Double = (v["jitterBufferDelay"] as? NSNumber)?.doubleValue ?? 0
        let jitterBufferEmittedCount: Int64 = (v["jitterBufferEmittedCount"] as? NSNumber)?.int64Value ?? 0
        let freezeCount: Int64 = (v["freezeCount"] as? NSNumber)?.int64Value ?? 0
        let totalFreezesDurationSec: Double = (v["totalFreezesDuration"] as? NSNumber)?.doubleValue ?? 0

        // RTT comes from the candidate-pair, in seconds.
        let roundTripTimeMs: Double? = {
            guard let rtt = (candidatePair?.values["currentRoundTripTime"] as? NSNumber)?.doubleValue else { return nil }
            return rtt * 1000
        }()

        // Deltas — only meaningful when we have a previous sample.
        let decodeTimePerFrameMs: Double? = {
            guard let prevDecode = previousTotalDecodeTime,
                  let prevFrames = previousFramesDecoded
            else { return nil }
            let deltaFrames = framesDecoded - prevFrames
            guard deltaFrames > 0 else { return nil }
            let deltaSeconds = max(0, totalDecodeTime - prevDecode)
            return (deltaSeconds / Double(deltaFrames)) * 1000
        }()
        let playbackDelayMs: Double? = {
            guard let prevDelay = previousJitterBufferDelay,
                  let prevCount = previousJitterBufferEmittedCount
            else { return nil }
            let deltaCount = jitterBufferEmittedCount - prevCount
            guard deltaCount > 0 else { return nil }
            let deltaSeconds = max(0, jitterBufferDelay - prevDelay)
            return (deltaSeconds / Double(deltaCount)) * 1000
        }()

        // Composite input-latency estimate: full RTT (input goes
        // there, frame comes back) + jitter buffer + decode.
        // Lower bound — the host's display refresh and JetKVM's
        // capture+encode aren't observable, so reality is ~30-50 ms
        // worse. Always > RTT.
        let endToEndLatencyMs: Double? = {
            guard let rtt = roundTripTimeMs,
                  let buf = playbackDelayMs,
                  let dec = decodeTimePerFrameMs
            else { return nil }
            return rtt + buf + dec
        }()

        previousTotalDecodeTime = totalDecodeTime
        previousFramesDecoded = framesDecoded
        previousJitterBufferDelay = jitterBufferDelay
        previousJitterBufferEmittedCount = jitterBufferEmittedCount

        return ConnectionStats(
            timestamp: now,
            roundTripTimeMs: roundTripTimeMs,
            jitterMs: jitterSeconds.map { $0 * 1000 },
            packetsReceived: packetsReceived,
            packetsLost: packetsLost,
            connectionType: connectionType,
            framesPerSecond: framesPerSecond,
            codec: codec,
            freezeCount: freezeCount,
            totalFreezesDurationSec: totalFreezesDurationSec,
            decodeTimePerFrameMs: decodeTimePerFrameMs,
            playbackDelayMs: playbackDelayMs,
            endToEndLatencyMs: endToEndLatencyMs,
            traffic: traffic(allStats.values.map { ($0.id, $0.type, $0.values) })
        )
    }

    /// Splits the connection's bytes by what they carried. The transport
    /// stats count everything on the wire (SRTP, SCTP, DTLS, RTCP); video
    /// and each data channel count their own payload; the remainder is
    /// `.other`. Data channels count a message when it's handed to SCTP,
    /// so during a big upload they can run ahead of the transport by the
    /// SCTP send queue and `.other` reads 0 until the wire catches up.
    /// Takes the report's stats as plain tuples so tests can feed it.
    mutating func traffic(
        _ stats: [(id: String, type: String, values: [String: NSObject])]
    ) -> [TrafficCategory: ByteCounts] {
        func int(_ value: NSObject?) -> Int64 { (value as? NSNumber)?.int64Value ?? 0 }

        let v = stats.first { $0.type == "inbound-rtp" && $0.values["kind"] as? String == "video" }?.values ?? [:]
        for stat in stats where stat.type == "data-channel" {
            let label = stat.values["label"] as? String ?? ""
            dataChannels[stat.id] = (
                Self.category(forDataChannel: label),
                ByteCounts(received: int(stat.values["bytesReceived"]), sent: int(stat.values["bytesSent"]))
            )
        }
        var traffic: [TrafficCategory: ByteCounts] = [
            .video: ByteCounts(received: int(v["bytesReceived"]) + int(v["headerBytesReceived"])),
        ]
        for channel in dataChannels.values {
            traffic[channel.category, default: ByteCounts()] = traffic[channel.category, default: ByteCounts()] + channel.bytes
        }

        let wire = stats.filter { $0.type == "transport" }.reduce(ByteCounts()) {
            $0 + ByteCounts(received: int($1.values["bytesReceived"]), sent: int($1.values["bytesSent"]))
        }
        let attributed = traffic.values.reduce(ByteCounts(), +)
        traffic[.other, default: ByteCounts()] = traffic[.other, default: ByteCounts()] + ByteCounts(
            received: max(0, wire.received - attributed.received),
            sent: max(0, wire.sent - attributed.sent)
        )
        return traffic
    }

    /// The traffic a data channel carries, by its label. The labels are
    /// the JetKVM firmware's.
    static func category(forDataChannel label: String) -> TrafficCategory {
        switch label {
        case "rpc": return .control
        case "host_bridge": return .clipboardAndFiles
        case _ where label.hasPrefix("hidrpc"): return .input
        case _ where label.hasPrefix("guestfile_"): return .clipboardAndFiles
        default: return .other
        }
    }
}
