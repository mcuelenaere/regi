import Charts
import SwiftUI
import KVMKit

/// Popover content showing live WebRTC connection metrics.
/// Mirrors the diagnostic overlay the JetKVM web UI ships, plus a
/// few extras (composite end-to-end latency, connection type badge,
/// negotiated codec, total session bandwidth, freezes).
///
/// Each card pulls its current value from `session.latestStats` and
/// its sparkline from `session.statsHistory` — both update at ~1 Hz
/// from the WebRTCFacade stats poller.
struct StatsPanel: View {
    @Environment(Session.self) private var session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                badgesRow
                section("Network") {
                    grid {
                        MetricCard(
                            title: "Bitrate",
                            value: latest?.bitrateBitsPerSecond.map(formatBitrate) ?? "—",
                            samples: history,
                            sample: { $0.bitrateBitsPerSecond }
                        )
                        MetricCard(
                            title: "Round-trip",
                            value: latest?.roundTripTimeMs.map { "\(Int($0.rounded())) ms" } ?? "—",
                            samples: history,
                            sample: { $0.roundTripTimeMs }
                        )
                        MetricCard(
                            title: "Jitter",
                            value: latest?.jitterMs.map { String(format: "%.1f ms", $0) } ?? "—",
                            samples: history,
                            sample: { $0.jitterMs }
                        )
                        MetricCard(
                            title: "Packet loss",
                            value: latest?.packetLossPercent.map { String(format: "%.2f%%", $0) } ?? "—",
                            samples: history,
                            sample: { $0.packetLossPercent }
                        )
                    }
                }
                section("Video") {
                    grid {
                        MetricCard(
                            title: "FPS",
                            value: latest.map { "\(Int($0.framesPerSecond.rounded()))" } ?? "—",
                            samples: history,
                            sample: { $0.framesPerSecond }
                        )
                        MetricCard(
                            title: "Decode time",
                            value: latest?.decodeTimePerFrameMs.map { String(format: "%.1f ms", $0) } ?? "—",
                            samples: history,
                            sample: { $0.decodeTimePerFrameMs }
                        )
                    }
                }
                section("Latency") {
                    grid {
                        MetricCard(
                            title: "Input latency",
                            value: latest?.endToEndLatencyMs.map { "\(Int($0.rounded())) ms" } ?? "—",
                            samples: history,
                            sample: { $0.endToEndLatencyMs },
                            highlight: true
                        )
                        MetricCard(
                            title: "Playback delay",
                            value: latest?.playbackDelayMs.map { String(format: "%.1f ms", $0) } ?? "—",
                            samples: history,
                            sample: { $0.playbackDelayMs }
                        )
                    }
                }
                sessionFooter
            }
            .padding(20)
        }
        .frame(width: 460, height: 580)
    }

    // MARK: - Helpers

    private var latest: ConnectionStats? { session.latestStats }
    private var history: [ConnectionStats] { session.statsHistory }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    @ViewBuilder
    private func grid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            content()
        }
    }

    @ViewBuilder
    private var badgesRow: some View {
        HStack(spacing: 12) {
            Badge(
                label: "Connection",
                value: latest?.connectionType.map(connectionTypeLabel) ?? "—",
                tint: connectionTint
            )
            Badge(
                label: "Codec",
                value: latest?.codec.flatMap(codecLabel) ?? "—",
                tint: .secondary
            )
            Badge(
                label: "Quality",
                value: session.streamQualityFactor
                    .map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                tint: .secondary
            )
        }
    }

    @ViewBuilder
    private var sessionFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session totals")
                .font(.headline)
            HStack(spacing: 24) {
                FooterStat(
                    label: "Bandwidth used",
                    value: latest.map { formatBytes($0.bytesReceivedTotal) } ?? "—"
                )
                FooterStat(
                    label: "Packets received",
                    value: latest.map { decimal($0.packetsReceived) } ?? "—"
                )
                FooterStat(
                    label: "Packets lost",
                    value: latest.map { decimal($0.packetsLost) } ?? "—"
                )
                FooterStat(
                    label: "Freezes",
                    value: latest.map {
                        $0.freezeCount == 0
                            ? "0"
                            : "\($0.freezeCount) (\(String(format: "%.1fs", $0.totalFreezesDurationSec)))"
                    } ?? "—"
                )
            }
        }
    }

    // MARK: - Formatting

    private func formatBitrate(_ bps: Double) -> String {
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", bps / 1_000_000)
        } else if bps >= 1_000 {
            return String(format: "%.0f kbps", bps / 1_000)
        } else {
            return String(format: "%.0f bps", bps)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024)
        } else if mb >= 1 {
            return String(format: "%.1f MB", mb)
        } else {
            return String(format: "%.0f KB", Double(bytes) / 1024)
        }
    }

    private func decimal(_ n: Int64) -> String {
        n.formatted(.number)
    }

    private func connectionTypeLabel(_ type: ConnectionType) -> String {
        switch type {
        case .host:  return "Direct (LAN)"
        case .srflx: return "NAT-traversed"
        case .prflx: return "Peer-reflexive"
        case .relay: return "Relay (TURN)"
        }
    }

    private var connectionTint: Color {
        switch latest?.connectionType {
        case .host?: return .green
        case .srflx?, .prflx?: return .blue
        case .relay?: return .orange
        case nil: return .secondary
        }
    }

    /// Strip the "video/" prefix from the W3C codec mimeType.
    private func codecLabel(_ mimeType: String) -> String? {
        if let slash = mimeType.firstIndex(of: "/") {
            return String(mimeType[mimeType.index(after: slash)...])
        }
        return mimeType
    }
}

// MARK: - Card components

private struct MetricCard: View {
    let title: String
    let value: String
    let samples: [ConnectionStats]
    let sample: (ConnectionStats) -> Double?
    var highlight: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(highlight ? .title3.monospacedDigit() : .body.monospacedDigit())
                .fontWeight(highlight ? .semibold : .regular)
            sparkline
                .frame(height: 32)
                .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var sparkline: some View {
        let plotted = samples.compactMap { stat -> (Date, Double)? in
            guard let v = sample(stat) else { return nil }
            return (stat.timestamp, v)
        }
        if plotted.count >= 2 {
            Chart {
                ForEach(plotted, id: \.0) { point in
                    LineMark(
                        x: .value("t", point.0),
                        y: .value("v", point.1)
                    )
                    .interpolationMethod(.linear)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
        } else {
            // Not enough points for a line; show an empty box so
            // the layout doesn't reflow once the second sample arrives.
            Rectangle()
                .fill(Color.secondary.opacity(0.1))
                .cornerRadius(2)
        }
    }
}

private struct Badge: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.medium))
                .foregroundStyle(tint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }
}

private struct FooterStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }
}
