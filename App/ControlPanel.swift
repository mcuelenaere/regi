import SwiftUI
import JetKVMProtocol
import JetKVMTransport

/// Popover content with ATX power buttons, codec preference, stream
/// quality slider, and clipboard-sync toggle. Fed by Session's
/// cached control-plane state — Session refreshes once when the rpc
/// channel opens.
struct ControlPanel: View {
    @Environment(Session.self) private var session
    /// The power action awaiting confirmation, if any. Drives the single
    /// confirmation dialog shared by all destructive power buttons.
    @State private var confirmAction: KVMPowerAction?
    @State private var pendingError: String?
    /// Persisted across launches; consumed by ClipboardSyncManager
    /// in KVMSessionWindow to decide whether to actually shuttle
    /// pasteboard data. Off by default — every local clipboard
    /// write while it's on flows to the connected host.
    @AppStorage("RegiClipboardSyncEnabled") private var clipboardSyncEnabled: Bool = false

    private var rpcDisabled: Bool { !session.rpcReady }

    private var caps: KVMCapabilities { session.capabilities }
    private var hasPowerControls: Bool { !session.availablePowerActions.isEmpty }
    private var hasAnyControls: Bool {
        hasPowerControls || caps.videoCodecPreference || caps.streamQuality || caps.clipboardSync
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Sections are gated on device capabilities so a PiKVM
            // session (no control plane in v1) doesn't show JetKVM-only
            // controls. Each owns a trailing Divider except the last.
            if hasPowerControls {
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

    /// One backend-agnostic power section. The active backend advertises which
    /// `KVMPowerAction`s it can perform (JetKVM ATX, VNC XVP); we render a
    /// button per action and switch display copy on the case. No per-backend
    /// branching — the section only appears when the backend has power control.
    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Power").font(.headline)
                Spacer()
                if let on = session.powerIndicator {
                    Label(on ? "On" : "Off", systemImage: on ? "circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(on ? .green : .secondary)
                }
            }
            HStack(spacing: 8) {
                ForEach(session.availablePowerActions, id: \.self) { action in
                    Button(Self.presentation(for: action).title) {
                        if Self.presentation(for: action).isDestructive {
                            confirmAction = action
                        } else {
                            perform(action)
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            confirmAction.map { Self.presentation(for: $0).confirmTitle } ?? "",
            isPresented: Binding(
                get: { confirmAction != nil },
                set: { if !$0 { confirmAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmAction
        ) { action in
            Button(Self.presentation(for: action).confirmButton, role: .destructive) {
                perform(action)
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(Self.presentation(for: action).confirmMessage)
        }
    }

    private func perform(_ action: KVMPowerAction) {
        Task { await runAction { try await session.sendPowerAction(action) } }
    }

    /// Display copy for a power action. Semantics live in `KVMPowerAction`
    /// (KVMCore); the wording is a UI concern and stays here.
    private struct PowerPresentation {
        let title: LocalizedStringKey
        let isDestructive: Bool
        let confirmTitle: LocalizedStringKey
        let confirmButton: LocalizedStringKey
        let confirmMessage: LocalizedStringKey
    }

    private static func presentation(for action: KVMPowerAction) -> PowerPresentation {
        switch action {
        case .powerButtonShort:
            return .init(title: "Power", isDestructive: false, confirmTitle: "", confirmButton: "", confirmMessage: "")
        case .powerButtonLong:
            return .init(title: "Force Off…", isDestructive: true, confirmTitle: "Force-power off?", confirmButton: "Force Off", confirmMessage: "Holds the power button for 5 seconds.")
        case .reset:
            return .init(title: "Reset…", isDestructive: true, confirmTitle: "Reset the machine?", confirmButton: "Reset", confirmMessage: "Sends a hard reset. Unsaved state is lost.")
        case .shutdown:
            return .init(title: "Shut Down…", isDestructive: true, confirmTitle: "Shut down?", confirmButton: "Shut Down", confirmMessage: "Sends an ACPI shutdown request to the guest.")
        case .reboot:
            return .init(title: "Reboot…", isDestructive: true, confirmTitle: "Reboot?", confirmButton: "Reboot", confirmMessage: "Reboots the guest.")
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

    @ViewBuilder
    private var clipboardSection: some View {
        // VNC exposes a text-only clipboard surface; JetKVM uses the agent
        // bridge. Only one is non-nil at a time.
        if let textClipboard = session.textClipboard {
            vncClipboardSection(textClipboard)
        } else {
            jetKVMClipboardSection
        }
    }

    private var jetKVMClipboardSection: some View {
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

    private func vncClipboardSection(_ clipboard: VNCTextClipboard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Clipboard sync").font(.headline)
                Spacer()
                Text(clipboard.supportsUTF8 ? "UTF-8 clipboard" : "Basic clipboard")
                    .font(.caption)
                    .foregroundStyle(clipboard.isAvailable ? .green : .secondary)
            }
            Toggle("Sync text clipboard with guest", isOn: $clipboardSyncEnabled)
                .disabled(!clipboard.isAvailable)
            if !clipboard.isAvailable {
                Text("Connect to sync the clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if clipboardSyncEnabled {
                Text("Text-only sync, both directions. UTF-8 needs a guest clipboard agent (e.g. spice-vdagent with `-vga …,clipboard=vnc`); otherwise Latin-1 only. Password-manager copies marked transient are skipped.")
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
