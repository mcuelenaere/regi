import AppKit
import SwiftUI
import JetKVMTransport

/// One window per connected host. Owns its own Session so multiple
/// windows for different hosts can coexist. The connection flow runs
/// inline inside the window — ConnectionStatusView until .connected,
/// then crossfade to KVMWindowView.
///
/// On window close (.onDisappear) we tear the session down so the
/// peer connection / signaling WS / cookie state don't leak. The user
/// re-opens by clicking the host again in HostsView.
struct KVMSessionWindow: View {
    let sessionID: KVMSessionWindowID
    @State private var session = Session()
    @State private var ownWindow: NSWindow?
    /// True between this window's didEnterFullScreen and
    /// didExitFullScreen notifications. Drives StatusStrip
    /// suppression and the system-presentation-options hide.
    @State private var isFullscreen = false
    /// Pending pause-after-debounce. Replaced/cancelled whenever the
    /// window's visibility changes — gives the user a 5s grace period
    /// before we ask the device to pause encoder feed.
    @State private var pauseTask: Task<Void, Never>?
    /// Debounce window before pausing on hide. Quick alt-tab /
    /// occlusion blips don't trigger a pause / resume cycle (each of
    /// which costs an IDR on resume).
    private static let pauseDebounce: Duration = .seconds(5)
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(TrustedHostStore.self) private var trustStore

    var body: some View {
        // VStack(ZStack(KVM + overlay), StatusStrip): the StatusStrip
        // sits BELOW the overlay-stacked region so it remains visible
        // during the ConnectionStatusView "Receiving video stream…"
        // phase. The overlay only covers the video area, not the
        // status bar — gives the user FPS/RTT/etc. as soon as they're
        // available.
        VStack(spacing: 0) {
            ZStack {
                if isConnectedOrLater {
                    KVMWindowView()
                }
                if shouldShowOverlay {
                    ConnectionStatusView(
                        displayName: sessionID.displayName,
                        urlString: sessionID.urlString,
                        host: sessionID.host,
                        endpoint: currentEndpoint,
                        onCancel: { dismissWindow() },
                        onRetry: { Task { await connect() } },
                        onAcceptTrust: { Task { await acceptTrustAndRetry() } }
                    )
                    .transition(.opacity)
                }
            }
            if isConnectedOrLater && !isFullscreen {
                StatusStrip()
            }
        }
        .environment(session)
        .navigationTitle(sessionID.displayName)
        .background(WindowAccessor(window: $ownWindow))
        .task {
            // First connection attempt fires on appear. We use .task
            // (not .onAppear) so the connect coroutine is cancelled if
            // the window goes away mid-flight.
            await connect()
        }
        .onDisappear {
            // Session.disconnect is async; fire-and-forget so the
            // window-close path stays synchronous. The session reaches
            // .idle and gets deallocated when this view's @State drops.
            Task { await session.disconnect() }
            // Drop any pending pause so it doesn't fire against a
            // disconnecting / dead session.
            pauseTask?.cancel()
            pauseTask = nil
            // If we exit while still fullscreen (e.g. user closes the
            // window from a fullscreen Space), clear our presentation
            // override so the menu bar / dock come back for the next
            // window.
            if isFullscreen {
                FullscreenPresentationCounter.shared.exit()
                isFullscreen = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didEnterFullScreenNotification)
        ) { note in
            guard let win = note.object as? NSWindow, win === ownWindow else { return }
            isFullscreen = true
            FullscreenPresentationCounter.shared.enter()
            // Suppress the window's toolbar entirely so it doesn't
            // slide back in when the cursor reaches the top of the
            // screen. NSApp.presentationOptions only governs the
            // system menu bar / dock; the window's own title-bar
            // reveal is separate macOS behavior.
            win.toolbar?.isVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didExitFullScreenNotification)
        ) { note in
            guard let win = note.object as? NSWindow, win === ownWindow else { return }
            isFullscreen = false
            FullscreenPresentationCounter.shared.exit()
            win.toolbar?.isVisible = true
        }
        // Bandwidth gate: pause the encoder feed when the window is
        // minimized or fully occluded by other windows; resume the
        // moment it becomes visible again. The pause is debounced
        // (5s) so a quick alt-tab doesn't cost an IDR on resume.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didChangeOcclusionStateNotification)
        ) { note in
            guard (note.object as? NSWindow) === ownWindow else { return }
            updateBandwidthGate()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didMiniaturizeNotification)
        ) { note in
            guard (note.object as? NSWindow) === ownWindow else { return }
            updateBandwidthGate()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didDeminiaturizeNotification)
        ) { note in
            guard (note.object as? NSWindow) === ownWindow else { return }
            updateBandwidthGate()
        }
    }

    private var isConnectedOrLater: Bool {
        switch session.state {
        case .connected, .kicked, .reconnecting:
            return true
        default:
            return false
        }
    }

    private var shouldShowOverlay: Bool {
        // Overlay appears for everything except the steady "we have
        // video and the user is operating the host" state. .kicked
        // and .reconnecting render their own banner inside
        // KVMWindowView, so we suppress the overlay for those.
        switch session.state {
        case .idle, .connecting, .awaitingPassword, .awaitingTrustOverride, .failed:
            return true
        case .connected:
            // ICE is up and the track is attached, but actual frames
            // can take hundreds of ms to start rendering. Keep the
            // overlay until the renderer reports a non-zero video
            // size (markFirstFrameReceived); otherwise the user sees
            // a blank black window for a beat.
            if session.hasReceivedFirstFrame { return false }
            // Exception: the device is already telling us it has no
            // HDMI signal (e.g. host machine powered off). Frames
            // won't arrive — drop the spinner so the no-signal
            // placeholder in KVMWindowView shows instead.
            if let err = session.videoState?.error, !err.isEmpty { return false }
            return true
        case .reconnecting, .kicked:
            return false
        }
    }

    /// DeviceEndpoint reflecting the persisted TLS-trust opt-in for
    /// this host. `trustStore.isTrusted` is keyed by host string so
    /// the result is stable across window recreations and mDNS-
    /// discovered vs. SavedHost flows.
    private var currentEndpoint: DeviceEndpoint {
        DeviceEndpoint(
            host: sessionID.host,
            port: sessionID.port,
            useTLS: sessionID.useTLS,
            allowSelfSignedCertificate: trustStore.isTrusted(sessionID.host)
        )
    }

    private func connect() async {
        let saved = PasswordVault.load(for: sessionID.host)
        await session.connect(endpoint: currentEndpoint, password: saved)
    }

    /// Called when the user clicks "Trust certificate" on the
    /// awaitingTrustOverride card. Persists the opt-in to
    /// TrustedHostStore (keyed by host) so every future window for
    /// this host skips the prompt, then re-runs the connect flow.
    private func acceptTrustAndRetry() async {
        trustStore.trust(sessionID.host)
        await connect()
    }

    /// Decide whether the encoder feed should be running based on the
    /// window's current visibility, and schedule pause/resume RPCs to
    /// reflect that. Visibility = window not minimized AND at least
    /// partly on-screen (occlusionState includes .visible).
    ///
    /// Pause is debounced by `pauseDebounce` so a quick alt-tab
    /// doesn't trigger the cycle. Resume fires immediately so the
    /// user never waits for video on returning to the window.
    private func updateBandwidthGate() {
        guard let window = ownWindow else { return }
        let visible = !window.isMiniaturized
            && window.occlusionState.contains(.visible)
        if visible {
            // Cancel any pending pause and resume now. The server's
            // resume is a no-op when not paused, so spurious calls
            // are harmless.
            pauseTask?.cancel()
            pauseTask = nil
            session.resumeVideo()
        } else {
            // Schedule pause after the debounce window. Replace any
            // pending one so the timer restarts on each event.
            pauseTask?.cancel()
            let session = self.session
            pauseTask = Task { @MainActor in
                try? await Task.sleep(for: Self.pauseDebounce)
                if Task.isCancelled { return }
                session.pauseVideo()
            }
        }
    }
}

extension KVMSessionWindowID {
    /// Round-trippable URL string for the connect-overlay's subtitle.
    /// Drops the port suffix when it matches the scheme default.
    var urlString: String {
        let scheme = useTLS ? "https" : "http"
        let usingDefaultPort = (useTLS && port == 443) || (!useTLS && port == 80)
        return usingDefaultPort ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }
}

/// Resolves the NSWindow hosting the SwiftUI view it's attached to,
/// publishing the reference back through a Binding. Used by
/// KVMSessionWindow to scope NSWindow.didEnterFullScreenNotification
/// observers to its OWN window — the notification posts for any
/// app window, but with multiple sessions open we only want to react
/// when our specific window changes fullscreen state.
private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window !== nsView.window {
            DispatchQueue.main.async {
                window = nsView.window
            }
        }
    }
}

/// Reference counts how many KVMSessionWindows are currently in
/// fullscreen so we apply NSApp.presentationOptions exactly once and
/// revert exactly once. NSApp.presentationOptions is process-global —
/// a single set/clear pair would race when two windows fullscreen at
/// the same time (e.g. the second exit clobbering the first's hide).
@MainActor
private final class FullscreenPresentationCounter {
    static let shared = FullscreenPresentationCounter()
    private var refCount = 0

    func enter() {
        refCount += 1
        if refCount == 1 {
            // .hideMenuBar (not .autoHide…) so the menu bar stays
            // hidden even when the cursor reaches the top of the
            // screen — the host's display would otherwise lose its
            // top row every time the user nudged the mouse upward.
            NSApp.presentationOptions = [.hideMenuBar, .hideDock]
        }
    }

    func exit() {
        refCount = max(0, refCount - 1)
        if refCount == 0 {
            NSApp.presentationOptions = []
        }
    }
}
