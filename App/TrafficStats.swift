// SPDX-License-Identifier: AGPL-3.0-or-later

import Charts
import SwiftUI
import KVMKit

extension TrafficCategory {
    var label: String {
        switch self {
        case .video: return "Video"
        case .input: return "Input"
        case .clipboardAndFiles: return "Clipboard & files"
        case .control: return "Control"
        case .other: return "Other"
        }
    }

    var color: Color {
        switch self {
        case .video: return .blue
        case .input: return .green
        case .clipboardAndFiles: return .orange
        case .control: return .purple
        case .other: return .gray
        }
    }
}

/// Live throughput, stacked by category: received above the axis, sent
/// below it.
struct TrafficCard: View {
    let samples: [ConnectionStats]

    private struct Point: Identifiable {
        let time: Date
        let category: TrafficCategory
        let sent: Bool
        let start: Double
        let end: Double
        var id: String { "\(time.timeIntervalSince1970)-\(category)-\(sent)" }
    }

    /// Per-pair rates, stacked by hand so received and sent stack away
    /// from zero in opposite directions.
    private var points: [Point] {
        zip(samples, samples.dropFirst()).flatMap { earlier, later in
            let rates = later.trafficRates(since: earlier)
            var up = 0.0, down = 0.0
            return TrafficCategory.allCases.flatMap { category -> [Point] in
                let r = rates[category] ?? (0, 0)
                defer { up += r.received; down -= r.sent }
                return [
                    Point(time: later.timestamp, category: category, sent: false, start: up, end: up + r.received),
                    Point(time: later.timestamp, category: category, sent: true, start: down, end: down - r.sent),
                ]
            }
        }
    }

    /// Categories that carried anything this window; the rest stay out of
    /// the legend.
    private var active: [TrafficCategory] {
        guard let first = samples.first, let last = samples.last else { return [] }
        return TrafficCategory.allCases.filter { (last.traffic[$0] ?? ByteCounts()) != (first.traffic[$0] ?? ByteCounts()) }
    }

    var body: some View {
        let latest = samples.count >= 2
            ? samples[samples.count - 1].trafficRates(since: samples[samples.count - 2]).values
                .reduce((received: 0.0, sent: 0.0)) { ($0.received + $1.received, $0.sent + $1.sent) }
            : nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Traffic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(latest.map { "↓ \(formatBitrate($0.received))   ↑ \(formatBitrate($0.sent))" } ?? "—")
                    .font(.body.monospacedDigit())
            }
            chart
                .frame(height: 32)
                .padding(.top, 2)
            HStack(spacing: 10) {
                ForEach(active, id: \.self) { category in
                    HStack(spacing: 4) {
                        Circle().fill(category.color.opacity(0.7)).frame(width: 7, height: 7)
                        Text(category.label)
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var chart: some View {
        let points = points
        if points.isEmpty {
            Rectangle()
                .fill(Color.secondary.opacity(0.1))
                .cornerRadius(2)
        } else {
            Chart {
                ForEach(points) { p in
                    AreaMark(
                        x: .value("t", p.time),
                        yStart: .value("start", p.start),
                        yEnd: .value("end", p.end),
                        series: .value("series", "\(p.category)-\(p.sent)")
                    )
                    .foregroundStyle(p.category.color.opacity(0.7))
                    .interpolationMethod(.linear)
                }
                RuleMark(y: .value("zero", 0))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
        }
    }
}

/// Session byte totals per category, both directions.
struct TrafficTotals: View {
    let traffic: [TrafficCategory: ByteCounts]

    var body: some View {
        let rows = TrafficCategory.allCases.filter { (traffic[$0] ?? ByteCounts()) != ByteCounts() }
        Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 3) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                Text("Received")
                Text("Sent")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(rows, id: \.self) { category in
                GridRow {
                    HStack(spacing: 5) {
                        Circle().fill(category.color.opacity(0.7)).frame(width: 7, height: 7)
                        Text(category.label)
                    }
                    bytes(traffic[category]?.received ?? 0)
                    bytes(traffic[category]?.sent ?? 0)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            let total = traffic.values.reduce(ByteCounts(), +)
            GridRow {
                Text("Total")
                bytes(total.received)
                bytes(total.sent)
            }
            .fontWeight(.medium)
        }
        .font(.callout.monospacedDigit())
    }

    private func bytes(_ n: Int64) -> Text {
        Text(n == 0 ? "—" : n.formatted(.byteCount(style: .binary)))
    }
}

func formatBitrate(_ bps: Double) -> String {
    if bps >= 1_000_000 {
        return String(format: "%.1f Mbps", bps / 1_000_000)
    } else if bps >= 1_000 {
        return String(format: "%.0f kbps", bps / 1_000)
    } else {
        return String(format: "%.0f bps", bps)
    }
}
