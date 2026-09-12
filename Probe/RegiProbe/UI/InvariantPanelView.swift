import ProbeKit
import SwiftUI

/// The panel you actually watch during a run: what is held right now, and
/// whether anything has gone wrong.
struct InvariantPanelView: View {
    let counters: InvariantCounters
    let held: Set<UInt16>
    let violations: [Violation]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                tile("up w/o down", counters.upWithoutDown)
                tile("dup down", counters.duplicateDown)
                tile("dropped", counters.droppedByRing)
                tile("injected", counters.syntheticSourceEvents)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Currently held")
                    .font(.caption).foregroundStyle(.secondary)
                if held.isEmpty {
                    Text("nothing").font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    // The stuck-key early warning.
                    Text(held.sorted().map(KeyLabels.label).joined(separator: "  "))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }

            if !violations.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Violations").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(violations.suffix(5).enumerated()), id: \.offset) { _, v in
                        Text(v.description)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func tile(_ label: String, _ value: UInt32) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(value == 0 ? Color.primary : Color.red)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(value == 0 ? Color.secondary.opacity(0.08) : Color.red.opacity(0.12)))
    }
}
