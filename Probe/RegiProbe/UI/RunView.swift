import ProbeKit
import SwiftUI

/// What the target's screen shows during a run — and therefore what travels
/// back through the KVM's video path.
///
/// Two audiences at once: the QR band is read by `regi-e2e`, and the
/// visualization is watched by a human *through Regi's own window*.
struct RunView: View {
    /// On-screen size of the QR band, in points on the target.
    ///
    /// This is the number that decides whether telemetry decodes at all.
    /// Module size at the *source* is bandSide / modulesAcross, and nothing
    /// downstream can recover detail the HDMI frame never carried — upscaling
    /// in Regi does not help. At 560pt a full 179-module symbol gave ~2.9
    /// px/module and stopped decoding entirely once the payload grew.
    static let bandSide: CGFloat = 880

    /// Chrome around the band in observe mode: just enough for a one-line
    /// status strip so the operator can see violations climbing without
    /// switching away from what they are doing.
    static let observeChrome: CGFloat = 34

    let model: ProbeModel
    /// Band-only layout for observe mode, where the window is a corner overlay
    /// rather than the screen. The full layout's timeline and panels are for a
    /// human watching through Regi; in observe mode they would only cover the
    /// app being tested.
    var compact: Bool = false
    let onStop: () -> Void

    /// The band's surroundings stay static while a run is active. Animation
    /// next to the code steals encoder bitrate from it, which is the suspected
    /// cause of decode-rate loss under motion.
    private var quietVisuals: Bool { model.runActive }

    var body: some View {
        if compact { observeBody } else { shieldedBody }
    }

    /// Band plus a status line. No Stop button: the window ignores mouse
    /// events so the clicks under test reach the app underneath, which means
    /// nothing in here could be clicked anyway. Stop lives in the main window.
    private var observeBody: some View {
        VStack(spacing: 0) {
            bandImage
            HStack(spacing: 10) {
                Circle()
                    .fill(model.counters.isClean ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("OBSERVE — target is NOT shielded")
                    .font(.system(size: 11, weight: .semibold))
                Text("up-without-down \(model.counters.upWithoutDown)  ·  frame \(model.framesRendered)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.observeChrome)
        }
        .background(Color.white)
        .preferredColorScheme(.light)
    }

    private var shieldedBody: some View {
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

    /// The code itself, at exactly `bandSide`. Kept separate from the caption
    /// so observe mode can show the band alone — there the window is sized to
    /// the band plus a status strip, and a caption would push the strip out.
    private var bandImage: some View {
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
        .frame(width: Self.bandSide, height: Self.bandSide)
        .border(Color.black.opacity(0.15))
    }

    private var qrBand: some View {
        VStack(spacing: 8) {
            bandImage

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

                InvariantPanelView(counters: model.counters,
                                   held: model.heldKeys,
                                   violations: model.violations)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Full width rather than sharing a 320pt column: event detail is
            // the most-read thing on this screen and it was truncating to
            // "cli…" and "flags 0x12…", which is exactly the part you need.
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent events").font(.caption).foregroundStyle(.secondary)
                EventTimelineView(events: model.recentEvents)
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.06)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
