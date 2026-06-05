import SwiftUI
import JetKVMProtocol
import JetKVMTransport

/// Popover content with ATX power buttons, codec preference, stream
/// quality slider, and clipboard-sync toggle. Fed by Session's
/// cached control-plane state — Session refreshes once when the rpc
/// channel opens.
struct ControlPanel: View {
    @Environment(Session.self) private var session
    @State private var showResetConfirm = false
    @State private var showPowerLongConfirm = false
    @State private var pendingError: String?
    /// Persisted across launches; consumed by ClipboardSyncManager
    /// in KVMSessionWindow to decide whether to actually shuttle
    /// pasteboard data. Off by default — every local clipboard
    /// write while it's on flows to the connected host.
    @AppStorage("RegiClipboardSyncEnabled") private var clipboardSyncEnabled: Bool = false

    private var rpcDisabled: Bool { !session.rpcReady }

    private var caps: KVMCapabilities { session.capabilities }
    private var hasAnyControls: Bool {
        caps.atxPower || caps.videoCodecPreference || caps.streamQuality || caps.clipboardSync
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Sections are gated on device capabilities so a PiKVM
            // session (no control plane in v1) doesn't show JetKVM-only
            // controls. Each owns a trailing Divider except the last.
            if caps.atxPower {
                powerSection
                Divider()
            }
            if caps.videoCodecPreference {
                codecSection
                Divider()
            }
            if caps.streamQuality {
                qualitySection
                Divider()
            }
            if caps.clipboardSync {
                clipboardSection
            }
            if !hasAnyControls {
                Text("No additional controls for this device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let err = pendingError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    // MARK: - Power

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Power").font(.headline)
                Spacer()
                if let atx = session.atxState {
                    Label(
                        atx.power ? "On" : "Off",
                        systemImage: atx.power ? "circle.fill" : "circle"
                    )
                    .font(.caption)
                    .foregroundStyle(atx.power ? .green : .secondary)
                }
            }
            HStack(spacing: 8) {
                Button("Power") {
                    Task { await runAction { try await session.setATXPowerAction(.powerShort) } }
                }
                .disabled(rpcDisabled)

                Button("Reset…") {
                    showResetConfirm = true
                }
                .disabled(rpcDisabled)
                .confirmationDialog(
                    "Reset host?",
                    isPresented: $showResetConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        Task { await runAction { try await session.setATXPowerAction(.reset) } }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Sends the reset signal to the host.")
                }

                Button("Force Off…") {
                    showPowerLongConfirm = true
                }
                .disabled(rpcDisabled)
                .confirmationDialog(
                    "Force-power off?",
                    isPresented: $showPowerLongConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Force Off", role: .destructive) {
                        Task { await runAction { try await session.setATXPowerAction(.powerLong) } }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Holds the power button for 5 seconds.")
                }
            }
        }
    }

    // MARK: - Codec

    private var codecSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codec preference").font(.headline)
            Picker(
                "Codec",
                selection: Binding(
                    get: { session.videoCodecPreference ?? .auto },
                    set: { newValue in
                        Task { await session.updateVideoCodecPreference(newValue) }
                    }
                )
            ) {
                Text("Auto").tag(VideoCodecPreference.auto)
                Text("H.264").tag(VideoCodecPreference.h264)
                Text("H.265").tag(VideoCodecPreference.h265)
            }
            .pickerStyle(.segmented)
            .disabled(rpcDisabled || session.videoCodecPreference == nil)
            Text("Takes effect on next reconnect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Quality

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stream quality").font(.headline)
                Spacer()
                if let factor = session.streamQualityFactor {
                    Text(String(format: "%.0f%%", factor * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Slider(
                value: Binding(
                    get: { session.streamQualityFactor ?? 1.0 },
                    set: { newValue in
                        Task { await session.updateStreamQualityFactor(newValue) }
                    }
                ),
                in: 0.1...1.0,
                step: 0.1
            )
            .disabled(rpcDisabled || session.streamQualityFactor == nil)
        }
    }

    // MARK: - Clipboard sync

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Clipboard sync").font(.headline)
                Spacer()
                Text(session.clipboardAgentState == .active ? "Agent connected" : "Agent disconnected")
                    .font(.caption)
                    .foregroundStyle(session.clipboardAgentState == .active ? .green : .secondary)
            }
            Toggle("Sync local clipboard with host", isOn: $clipboardSyncEnabled)
                .disabled(session.clipboardAgentState != .active)
            if session.clipboardAgentState != .active {
                Text("Install the JetKVM Helper on the host to enable clipboard sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if clipboardSyncEnabled {
                Text("Every local clipboard write while this is on flows to the host. Password-manager copies marked transient are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func runAction(_ action: @escaping () async throws -> Void) async {
        do {
            try await action()
            pendingError = nil
        } catch {
            pendingError = "\(error)"
        }
    }
}

/// Compact single-line strip showing the host video + USB state at
/// the bottom of the KVM window. Each segment is only rendered when
/// we have data to show — empty segments collapse rather than
/// rendering a "Loading…" placeholder.
struct StatusStrip: View {
    @Environment(Session.self) private var session

    var body: some View {
        HStack(spacing: 12) {
            videoSection
            Spacer()
            usbSection
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var videoSection: some View {
        if session.videoState != nil || session.latestStats != nil {
            HStack(spacing: 6) {
                Image(systemName: "display")
                // Resolution from getVideoState (host's HDMI capture).
                // Text(verbatim:) bypasses LocalizedStringKey, which
                // would otherwise insert locale thousand separators
                // into 1920 / 1080.
                if let video = session.videoState {
                    Text(verbatim: "\(video.width)×\(video.height)")
                        .monospacedDigit()
                }
                // Decoded FPS from WebRTC stats. Different from
                // videoState.fps (host's HDMI rate) — the stats one
                // reflects actual delivery to our decoder, which is
                // the user-feel "is video smooth right now" number.
                if let stats = session.latestStats, stats.framesPerSecond > 0 {
                    Text(verbatim: "\(Int(stats.framesPerSecond.rounded())) fps")
                        .monospacedDigit()
                }
                // Live RTT from the active ICE candidate pair.
                if let rtt = session.latestStats?.roundTripTimeMs {
                    Text(verbatim: "\(Int(rtt.rounded()))ms")
                        .monospacedDigit()
                }
                // Error string ("no_signal", "no_lock", …) only when
                // the JetKVM is reporting one.
                if let err = session.videoState?.error, !err.isEmpty {
                    Text(err.replacingOccurrences(of: "_", with: " "))
                        .foregroundStyle(.red)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var usbSection: some View {
        if let usb = session.usbState {
            HStack(spacing: 6) {
                Image(systemName: "cable.connector")
                Text(verbatim: "USB \(friendlyUSBState(usb))")
            }
            .foregroundStyle(.secondary)
        }
    }

    /// Map raw Linux UDC state strings to friendlier client-facing
    /// labels. `configured` is the USB-spec "fully enumerated and
    /// working" state — calling it "connected" matches the user's
    /// mental model better than the kernel's vocabulary.
    private func friendlyUSBState(_ raw: String) -> String {
        switch raw {
        case "configured": return "connected"
        case "addressed", "default", "powered", "attached", "connected":
            return "connecting"
        case "suspended": return "suspended"
        case "disconnected", "not attached": return "disconnected"
        default: return raw
        }
    }
}
