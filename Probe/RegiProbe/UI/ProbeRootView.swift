import ProbeKit
import SwiftUI

/// The idle window: readiness, then Start.
struct ProbeRootView: View {
    let model: ProbeModel
    let onStart: () -> Void
    let onObserve: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("RegiProbe")
                .font(.largeTitle.bold())
            Text("Records what input actually arrived on this machine, and renders it "
                 + "as a QR telemetry stream that travels back over the KVM's own video.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            readiness

            if let blocker = model.blocker {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(blocker).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            HStack {
                Button(action: onStart) {
                    Label("Start run", systemImage: "play.fill")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(model.blocker != nil)

                Button(action: onObserve) {
                    Label("Observe", systemImage: "eye")
                }
                .controlSize(.large)
                .disabled(model.blocker != nil)
                .help("Telemetry only, in a corner. The target is NOT shielded: "
                      + "clicks and keys reach its own apps.")

                if !model.accessibilityGranted {
                    Button("Grant Accessibility…") { model.requestAccessibility() }
                    Button("Open Settings…") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }

            Text("Starting opens a full-screen window. While it is up the keyboard is "
                 + "swallowed so stray ⌘Q cannot reach this machine's other apps; the "
                 + "pointer is left alone so Stop stays clickable — including through "
                 + "Regi. Esc ×5 always releases.\n\n"
                 + "Observe shows only the telemetry band, top-right, and shields "
                 + "nothing: input reaches this machine's own apps normally. Use it to "
                 + "reproduce a bug by hand in Finder or anywhere else while the probe "
                 + "records. Stop from this window.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            liveGlance
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 520)
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Accessibility", ok: model.accessibilityGranted,
                detail: model.accessibilityGranted ? "granted" : "required for the event tap")
            // Reported separately from the trust check on purpose: "Settings
            // shows it enabled but tapCreate returned nil" is the signature of a
            // re-signed binary, and is otherwise rediscovered from scratch.
            row("Event tap", ok: model.captureState == .running,
                detail: {
                    switch model.captureState {
                    case .running: return "capturing"
                    case .idle: return "not started"
                    case .failed(let m): return m
                    }
                }())
            row("Secure Input", ok: model.secureInputHolder == nil,
                detail: model.secureInputHolder.map { "held by \($0)" } ?? "clear")
        }
    }

    private func row(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(title).frame(width: 110, alignment: .leading)
            Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var liveGlance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live (capture runs even while idle)")
                .font(.caption).foregroundStyle(.secondary)
            KeyboardView(held: model.heldKeys, recent: model.keyRecency)
                .frame(height: 150)
            InvariantPanelView(counters: model.counters,
                               held: model.heldKeys,
                               violations: model.violations)

            HStack {
                Text("Recent events").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(get: { model.timelineFilter },
                                              set: { model.timelineFilter = $0 })) {
                    ForEach(EventKindFilter.allCases, id: \.self) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)
            }
            EventTimelineView(events: model.recentEvents)
                .frame(height: 160)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
        }
    }
}
