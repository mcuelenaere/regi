import ProbeKit
import SwiftUI

/// Newest-first list of what arrived. Earns its place twice over: it is how you
/// confirm character translation is correct, and it is the first thing to look
/// at when a scenario fails.
struct EventTimelineView: View {
    /// Newest first.
    let events: [ProbeEvent]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(rows, id: \.seq) { row in
                    HStack(spacing: 8) {
                        Text("\(row.seq)")
                            .frame(width: 52, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Text(row.delta)
                            .frame(width: 56, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Text(row.kind)
                            .frame(width: 56, alignment: .leading)
                            .foregroundStyle(row.isDiagnostic ? .red : .primary)
                        Text(row.detail)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }
            .padding(.vertical, 2)
        }
    }

    private struct Row { let seq: UInt64; let delta: String; let kind: String
                        let detail: String; let isDiagnostic: Bool }

    private var rows: [Row] {
        events.enumerated().map { i, e in
            // Gap to the *older* neighbour, which is the next element because
            // this list is newest-first.
            let older = i + 1 < events.count ? events[i + 1] : nil
            let delta: String
            if let older, e.machAbsoluteNanos >= older.machAbsoluteNanos {
                let ms = Double(e.machAbsoluteNanos - older.machAbsoluteNanos) / 1_000_000
                delta = ms < 1000 ? String(format: "+%.0fms", ms) : String(format: "+%.1fs", ms / 1000)
            } else {
                delta = ""
            }
            var isDiag = false
            if case .diagnostic = e.payload { isDiag = true }
            return Row(seq: e.seq, delta: delta, kind: e.kindLabel,
                       detail: e.detail, isDiagnostic: isDiag)
        }
    }
}
