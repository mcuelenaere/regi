import ProbeKit
import SwiftUI

/// What the target's screen shows during a run — and therefore what travels
/// back through the KVM's video path.
///
/// Two audiences at once: the QR band is read by `regi-e2e`, and the
/// visualization is watched by a human *through Regi's own window*.
struct RunView: View {
    let model: ProbeModel
    let onStop: () -> Void

    /// The band's surroundings stay static while a run is active. Animation
    /// next to the code steals encoder bitrate from it, which is the suspected
    /// cause of decode-rate loss under motion.
    private var quietVisuals: Bool { model.runActive }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 24) {
                qrBand
                visualization
            }
            .padding(24)
            Spacer(minLength: 0)
        }
        .background(Color.white)
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack {
            Label("RUN ACTIVE — keyboard is being swallowed", systemImage: "shield.fill")
                .font(.headline)
            Text("Esc ×5 releases")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("frame \(model.framesRendered)  ·  \(model.qrBytes) B  ·  \(model.qrEvents) events  ·  \(model.qrModules) modules")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Button("Stop", action: onStop)
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.18))
    }

    private var qrBand: some View {
        VStack(spacing: 8) {
            ZStack {
                // Plain white ground with a wide quiet zone: both matter for
                // decode rate through a compressed video stream.
                Rectangle().fill(.white)
                if let img = model.qrImage {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(24)
                } else {
                    Text("waiting for telemetry").foregroundStyle(.secondary)
                }
            }
            .frame(width: 560, height: 560)
            .border(Color.black.opacity(0.15))

            Text("telemetry — do not cover")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var visualization: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Quiet-visuals suppresses the decay glow while a run is
            // active: animation beside the QR band steals encoder bitrate
            // from it, which is the suspected cause of decode loss under
            // motion. Held state still renders — it just does not animate.
            KeyboardView(held: model.heldKeys,
                         recent: quietVisuals ? [:] : model.keyRecency)
                .frame(height: 220)

            HStack(alignment: .top, spacing: 16) {
                PointerCanvasView(trail: model.pointerTrail,
                                  screenSize: NSScreen.main?.frame.size ?? .zero)
                    .frame(width: 320, height: 200)
                    .border(Color.secondary.opacity(0.25))

                VStack(alignment: .leading, spacing: 8) {
                    InvariantPanelView(counters: model.counters,
                                       held: model.heldKeys,
                                       violations: model.violations)
                    EventTimelineView(events: model.recentEvents)
                        .frame(height: 150)
                }
                .frame(width: 320)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
