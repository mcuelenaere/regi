import KVMCore
import Foundation
import WebRTC

/// Walks an `RTCStatisticsReport` and produces a `ConnectionStats`.
///
/// Holds the previous sample's bytesReceived / decode / jitter-buffer
/// counters internally so it can compute deltas (bitrate, decode time
/// per frame, playback delay per frame) between calls. Discard and
/// recreate on disconnect — those deltas are nonsense across a
/// reconnect.
struct WebRTCStatsParser {
    private var previousBytesReceived: Int64?
    private var previousTimestamp: Date?
    private var previousTotalDecodeTime: Double?
    private var previousFramesDecoded: Int64?
    private var previousJitterBufferDelay: Double?
    private var previousJitterBufferEmittedCount: Int64?

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
        let bytesReceivedTotal: Int64 = (v["bytesReceived"] as? NSNumber)?.int64Value ?? 0
        let packetsReceived: Int64 = (v["packetsReceived"] as? NSNumber)?.int64Value ?? 0
        let packetsLost: Int64 = (v["packetsLost"] as? NSNumber)?.int64Value ?? 0
        let framesPerSecond: Double = (v["framesPerSecond"] as? NSNumber)?.doubleValue ?? 0
        let framesDropped: Int64 = (v["framesDropped"] as? NSNumber)?.int64Value ?? 0
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
        let bitrateBitsPerSecond: Double? = {
            guard let prevBytes = previousBytesReceived,
                  let prevTime = previousTimestamp
            else { return nil }
            let dt = now.timeIntervalSince(prevTime)
            guard dt > 0 else { return nil }
            let deltaBytes = max(0, bytesReceivedTotal - prevBytes)
            return Double(deltaBytes) * 8 / dt
        }()
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

        previousBytesReceived = bytesReceivedTotal
        previousTimestamp = now
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
            bitrateBitsPerSecond: bitrateBitsPerSecond,
            connectionType: connectionType,
            framesPerSecond: framesPerSecond,
            framesDropped: framesDropped,
            codec: codec,
            freezeCount: freezeCount,
            totalFreezesDurationSec: totalFreezesDurationSec,
            decodeTimePerFrameMs: decodeTimePerFrameMs,
            playbackDelayMs: playbackDelayMs,
            endToEndLatencyMs: endToEndLatencyMs,
            bytesReceivedTotal: bytesReceivedTotal
        )
    }
}
