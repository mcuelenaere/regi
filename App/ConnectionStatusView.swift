import SwiftUI
import KVMKit

/// Inline connection-flow UI shown inside a KVMSessionWindow before
/// the peer connection is up. Renders a centered card over a black
/// backdrop with phase / error / password fields based on
/// session.state. Crossfades out once .connected (the parent switches
/// to KVMWindowView).
struct ConnectionStatusView: View {
    @Environment(Session.self) private var session
    /// Title for the card — saved-host nickname or Bonjour instance.
    let displayName: String
    /// URL-shaped subtitle, e.g. "https://kvm.local".
    let urlString: String
    /// Hostname used as the keychain lookup key for password save.
    let host: String
    /// Endpoint to reconnect with when the user retries / submits
    /// a password.
    let endpoint: DeviceEndpoint
    /// Called when the user clicks Cancel. Parent closes the window.
    let onCancel: () -> Void
    /// Called when the user retries after a failure. Parent re-runs
    /// the connect flow with a fresh attempt.
    let onRetry: () -> Void
    /// Called when the user accepts the TLS-trust prompt. Parent is
    /// expected to flip `endpoint.allowSelfSignedCertificate`,
    /// persist that choice if the host is saved, and re-run connect.
    let onAcceptTrust: () -> Void

    @State private var password: String = ""
    @State private var rememberPassword: Bool = true

    private var connectingPhase: Session.State.Phase? {
        if case .connecting(let phase) = session.state { return phase } else { return nil }
    }

    private var isAwaitingPassword: Bool {
        if case .awaitingPassword = session.state { return true } else { return false }
    }

    /// Reason string from the underlying URLError when the cert chain
    /// didn't pass system trust. Surfaced verbatim in the prompt so
    /// the user sees e.g. `"JetKVM Self-Signed CA" certificate is not
    /// trusted` instead of a generic error.
    private var trustOverrideReason: String? {
        if case .awaitingTrustOverride(_, let reason) = session.state {
            return reason
        }
        return nil
    }

    private var failureMessage: String? {
        if case .failed(let msg) = session.state { return msg } else { return nil }
    }

    /// True between ICE-connected and the first video frame actually
    /// rendering. KVMSessionWindow keeps the overlay visible across
    /// this gap so we own the "video is on its way" affordance here.
    private var isAwaitingVideo: Bool {
        if case .connected = session.state, !session.hasReceivedFirstFrame {
            return true
        }
        return false
    }

    private var showSpinner: Bool {
        connectingPhase != nil || isAwaitingVideo
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            card
                .padding(28)
                // Solid background instead of `.thinMaterial`: macOS
                // materials apply vibrancy to overlaid text, which
                // desaturates colored content (red error text gets
                // washed out into the backdrop) — readability beats
                // the slightly nicer translucent look here.
                .background(
                    Color(NSColor.windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .shadow(radius: 16)
                .frame(minWidth: 360, idealWidth: 420, maxWidth: 460)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                if showSpinner {
                    ProgressView().controlSize(.small)
                }
                Text(displayName)
                    .font(.headline)
                Spacer()
            }

            Text(verbatim: urlString)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let phase = connectingPhase {
                Text(phase.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if isAwaitingVideo {
                Text("Receiving video stream…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let trustOverrideReason {
                trustOverrideSection(reason: trustOverrideReason)
            } else if isAwaitingPassword {
                passwordSection
            } else if let failureMessage {
                Text(failureMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(4)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                if failureMessage != nil {
                    Button("Retry") { onRetry() }
                        .keyboardShortcut(.defaultAction)
                }
                if isAwaitingPassword {
                    Button("Sign In") {
                        Task { await submitPassword() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
                }
                if trustOverrideReason != nil {
                    Button("Trust certificate") { onAcceptTrust() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Trust-prompt body shown when the device's TLS cert isn't in
    /// the system trust store and we don't yet have an opt-in. The
    /// reason string comes from URLError's localizedDescription so
    /// the user sees the actual cert name (e.g. "JetKVM Self-Signed
    /// CA"). Accepting persists to SavedHost via the parent so the
    /// prompt doesn't re-fire next time.
    private func trustOverrideSection(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This device's certificate isn't trusted by macOS.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Text("JetKVM ships with a self-signed certificate by default. Trusting it lets the connection proceed; the choice is remembered for this host.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Device requires a password.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await submitPassword() } }
            Toggle("Remember password", isOn: $rememberPassword)
                .help("Save the password to the macOS Keychain so it auto-fills next time you connect to this host.")
        }
    }

    @MainActor
    private func submitPassword() async {
        guard !password.isEmpty else { return }
        if rememberPassword {
            PasswordVault.save(password, for: host)
        } else {
            PasswordVault.delete(for: host)
        }
        await session.connect(endpoint: endpoint, password: password)
    }
}
