import SwiftUI
import JetKVMTransport

struct KVMWindowView: View {
    @Environment(Session.self) private var session
    @State private var capturer = KeyboardCapturer()
    @State private var pointerLock = PointerLockManager()
    @State private var hostKey = HostKeyDetector()
    @State private var keyboardMonitor: Any?
    @State private var showControls = false
    @State private var showStats = false

    /// UserDefaults key for the "Don't show this again" preference on
    /// the pointer-lock confirmation dialog.
    private static let skipPointerLockConfirmKey = "RegiSkipPointerLockConfirmation"

    /// User opt-in for hiding the macOS cursor over the rendered
    /// video sub-rect. Off by default — the cursor stays visible so
    /// the user can see where they're clicking. Stored via
    /// @AppStorage so the choice persists across launches and
    /// applies to all session windows.
    @AppStorage("RegiHideCursorOverVideo") private var hideCursorOverVideo: Bool = false

    /// Whether the connected device exposes any control-plane feature
    /// (ATX / codec / quality / clipboard). False for PiKVM v1, which
    /// hides the Controls toolbar item entirely.
    private var hasControlCapabilities: Bool {
        let c = session.capabilities
        return c.atxPower || c.videoCodecPreference || c.streamQuality || c.clipboardSync
    }

    /// Whether the Controls popover should be openable. JetKVM's controls ride
    /// its JSON-RPC channel (and self-disable inside the panel until it's
    /// ready), so gate on `rpcReady` there; VNC/PiKVM have no RPC channel, so a
    /// live connection is enough. `videoCodecPreference` is JetKVM-only, so it
    /// distinguishes the two without a device-kind check.
    private var controlsReady: Bool {
        guard case .connected = session.state else { return false }
        return session.rpcReady || !session.capabilities.videoCodecPreference
    }

    private var keyboardCaptureBinding: Binding<Bool> {
        Binding(
            // Only show as checked when capture is actually doing
            // something — `userIntent` alone goes true even when
            // accessibility was denied, which leaves the menu showing
            // a misleading checkmark next to a blocked feature. Both
            // .enabled and .suspended are "yes, this will be on as soon
            // as conditions allow"; .awaitingAccessibility / .failed /
            // .disabled aren't.
            get: { capturer.state == .enabled || capturer.state == .suspended },
            set: { newValue in
                if newValue { capturer.enable() } else { capturer.disable() }
            }
        )
    }

    private var pointerLockBinding: Binding<Bool> {
        Binding(
            get: { pointerLock.userIntent },
            set: { newValue in
                if newValue {
                    requestPointerLockEnable()
                } else {
                    pointerLock.disable()
                }
            }
        )
    }

    /// True when keyboard capture is effectively engaged — either
    /// actively running (`.enabled`) or paused because the app isn't
    /// frontmost (`.suspended`, which will re-engage on focus).
    /// `.awaitingAccessibility` / `.failed` don't count: those are
    /// "user asked but the system said no", which the menu shouldn't
    /// signal as a green-lit state in the toolbar.
    private var keyboardCaptureEngaged: Bool {
        capturer.state == .enabled || capturer.state == .suspended
    }

    private var pointerLockEngaged: Bool {
        pointerLock.state == .enabled || pointerLock.state == .suspended
    }

    /// Render `keyboard` + `magicmouse` side-by-side into a single
    /// template NSImage so the macOS toolbar can use it as the menu's
    /// icon. A plain HStack of two SwiftUI Image views *appears* to
    /// work but the toolbar's NSToolbarItem-image extraction grabs
    /// only the first child Image, silently dropping the second —
    /// hence the manual compositing.
    ///
    /// Each half is drawn at full alpha when its lock is engaged,
    /// 40% alpha when not. With `isTemplate = true` the system tints
    /// the result for the current toolbar style and dark/light mode;
    /// the partial alpha reads as a faded version of the same tint.
    ///
    /// Glyphs are drawn at their intrinsic size (after SymbolConfig
    /// scaling) so neither one is squished — `keyboard` is wider
    /// than `magicmouse`, and forcing both into equal squares makes
    /// the keyboard look compressed.
    private static func dualCaptureIcon(
        keyboardEngaged: Bool,
        pointerEngaged: Bool
    ) -> Image {
        let pointSize: CGFloat = 15
        let gap: CGFloat = 2
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let kbd = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        let mouse = NSImage(systemSymbolName: "magicmouse", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        let kbdSize = kbd?.size ?? .zero
        let mouseSize = mouse?.size ?? .zero
        let canvasWidth = kbdSize.width + gap + mouseSize.width
        let canvasHeight = max(kbdSize.height, mouseSize.height)
        let img = NSImage(
            size: NSSize(width: canvasWidth, height: canvasHeight),
            flipped: false
        ) { _ in
            if let kbd {
                kbd.draw(
                    in: NSRect(
                        x: 0,
                        y: (canvasHeight - kbdSize.height) / 2,
                        width: kbdSize.width,
                        height: kbdSize.height
                    ),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: keyboardEngaged ? 1.0 : 0.4
                )
            }
            if let mouse {
                mouse.draw(
                    in: NSRect(
                        x: kbdSize.width + gap,
                        y: (canvasHeight - mouseSize.height) / 2,
                        width: mouseSize.width,
                        height: mouseSize.height
                    ),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: pointerEngaged ? 1.0 : 0.4
                )
            }
            return true
        }
        img.isTemplate = true
        return Image(nsImage: img)
    }

    var body: some View {
        // No StatusStrip in here — it lives in KVMSessionWindow's
        // outer VStack so it stays visible during the
        // ConnectionStatusView overlay's "Receiving video stream…"
        // phase. The overlay only covers the video area then.
        ZStack {
            Color.black.ignoresSafeArea()
            if let err = videoSignalError {
                // Device is reporting an HDMI-side problem (cable
                // loose, host powered off, unsupported mode, …).
                // Frames won't flow; show the placeholder instead of
                // leaving the user staring at a black window.
                NoSignalPlaceholder(error: err)
            } else if let renderer = session.videoRenderer {
                KVMVideoRepresentable(
                    renderer: renderer,
                    session: session,
                    pointerLocked: pointerLock.state == .enabled,
                    hideCursorOverVideo: hideCursorOverVideo
                )
            } else {
                ProgressView("Waiting for video…")
                    .controlSize(.large)
                    .foregroundStyle(.white)
            }
            // Stack of top-of-window banners. Most-severe first.
            VStack(spacing: 8) {
                if case .kicked = session.state {
                    banner(
                        "Another peer connected to this device — your session was taken over.",
                        background: .red,
                        foreground: .white
                    )
                }
                if case .reconnecting(let attempt) = session.state {
                    banner(
                        "Connection lost — reconnecting (attempt \(attempt))…",
                        background: .orange,
                        foreground: .black
                    )
                }
                if let failsafe = session.failsafe, failsafe.active {
                    banner(
                        "Device is in failsafe mode: \(failsafe.reason)",
                        background: .red,
                        foreground: .white
                    )
                }
                if case .awaitingAccessibility = capturer.state {
                    banner(
                        "Grant Accessibility permission to capture system shortcuts (Cmd+Tab, Cmd+Space, …), then click Capture again.",
                        background: .yellow,
                        foreground: .black
                    )
                }
                Spacer()
            }
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle(isOn: keyboardCaptureBinding) {
                        Label("Keyboard lock", systemImage: "keyboard")
                    }
                    Toggle(isOn: pointerLockBinding) {
                        Label("Pointer lock", systemImage: "cursorarrow.rays")
                    }
                    Divider()
                    Toggle(isOn: $hideCursorOverVideo) {
                        Label("Hide cursor over video", systemImage: "cursorarrow.slash")
                    }
                } label: {
                    Self.dualCaptureIcon(
                        keyboardEngaged: keyboardCaptureEngaged,
                        pointerEngaged: pointerLockEngaged
                    )
                    .accessibilityLabel("Capture")
                }
                .help("Capture system keyboard shortcuts and/or lock the pointer for relative mouse mode. Optionally hide your local cursor over the video area when you'd rather see only the host's cursor. Keyboard capture requires Accessibility permission.")
            }
            if hasControlCapabilities {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showControls.toggle()
                    } label: {
                        Label("Controls", systemImage: "slider.horizontal.3")
                    }
                    .popover(isPresented: $showControls, arrowEdge: .top) {
                        ControlPanel()
                            .environment(session)
                    }
                    .disabled(!controlsReady)
                    .help("Power, codec, and quality controls.")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showStats.toggle()
                } label: {
                    Label("Stats", systemImage: "chart.line.uptrend.xyaxis")
                }
                .popover(isPresented: $showStats, arrowEdge: .top) {
                    StatsPanel()
                        .environment(session)
                }
                .help("Live network and video diagnostics.")
            }
        }
        // Publish actions for the app-wide File menu (RegiCommands).
        // While this window is focused, the menu shows session
        // commands (Controls / Connection Stats); when the hosts
        // window or no window is focused, the menu falls back to
        // "Add Host…". The standard close-window action (⌘W) tears
        // the session down via .onDisappear, so no explicit
        // Disconnect entry is needed.
        .focusedSceneValue(\.sessionActions, SessionActions(
            canShowControls: hasControlCapabilities && controlsReady,
            toggleControls: { showControls.toggle() },
            toggleStats: { showStats.toggle() }
        ))
        .onAppear {
            // Wire capturer event handlers into the same Session methods
            // KVMVideoView calls when the tap isn't installed. Same
            // contract: keyCode is the macOS Carbon virtual keycode.
            // Each handler also feeds HostKeyDetector so the ⌃⌥ release
            // chord works while keyboard-lock is on (the trapped case
            // — with keyboard-lock off, the user can already exit
            // pointer-lock via Cmd+Tab → focus loss → auto-suspend).
            capturer.onKeyDown = { [session, hostKey] keyCode in
                hostKey.didKeyDown(keyCode)
                session.sendKeypress(virtualKeyCode: keyCode, pressed: true)
            }
            capturer.onKeyUp = { [session, hostKey] keyCode in
                hostKey.didKeyUp(keyCode)
                session.sendKeypress(virtualKeyCode: keyCode, pressed: false)
            }
            capturer.onFlagsChanged = { [session] keyCode in
                session.handleFlagsChanged(virtualKeyCode: keyCode)
            }
            capturer.onModifierFlagsChanged = { [hostKey] flags in
                hostKey.didChangeFlags(flags)
            }
            // When capture pauses (focus loss or user toggling off
            // mid-keystroke), release any modifiers the tracker thinks
            // are held on the host. Without this, e.g. a Cmd-down sent
            // before a focus-out and a Cmd-up that the system swallowed
            // would leave the host with a stuck Cmd modifier.
            capturer.onSuspend = { [session, hostKey] in
                session.releaseAllHeldModifiers()
                hostKey.reset()
            }
            hostKey.onTriggered = { [pointerLock] in
                guard pointerLock.state == .enabled else { return }
                pointerLock.disable()
            }
            // Second feed path: an NSEvent local monitor catches
            // keyboard events delivered through the standard responder
            // chain — the path used when keyboard-lock is off (CGEventTap
            // not installed). When keyboard-lock IS on, events are
            // swallowed at the session-level tap before they reach the
            // WindowServer, so the monitor doesn't double-fire.
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.flagsChanged, .keyDown, .keyUp]
            ) { [hostKey] event in
                switch event.type {
                case .flagsChanged:
                    hostKey.didChangeFlags(event.modifierFlags)
                case .keyDown:
                    hostKey.didKeyDown(event.keyCode)
                case .keyUp:
                    hostKey.didKeyUp(event.keyCode)
                default:
                    break
                }
                return event
            }
        }
        .onDisappear {
            capturer.disable()
            pointerLock.disable()
            hostKey.reset()
            if let monitor = keyboardMonitor {
                NSEvent.removeMonitor(monitor)
                keyboardMonitor = nil
            }
        }
    }

    private func requestPointerLockEnable() {
        if UserDefaults.standard.bool(forKey: Self.skipPointerLockConfirmKey) {
            pointerLock.enable()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Lock pointer to JetKVM?")
        alert.informativeText = String(localized: """
            Your cursor will be hidden and pinned to this window, and mouse \
            movement sent as relative deltas to the device.

            To release the lock, press and hold ⌃⌥ (Control + Option) for half \
            a second.
            """)
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Lock pointer"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let checkbox = NSButton(
            checkboxWithTitle: String(localized: "Don't show this again"),
            target: nil,
            action: nil
        )
        checkbox.state = .off
        alert.accessoryView = checkbox
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if checkbox.state == .on {
            UserDefaults.standard.set(true, forKey: Self.skipPointerLockConfirmKey)
        }
        pointerLock.enable()
    }

    /// Top-of-window banner used for kicked / failsafe / accessibility
    /// states. All read better as a pinned strip than a popup, so we
    /// stack them at the top of the video view. Takes LocalizedStringKey
    /// (not String) so the Text initializer goes through the
    /// auto-localizing path — call sites pass string literals which
    /// Swift infers to the right type.
    private func banner(_ text: LocalizedStringKey, background: Color, foreground: Color) -> some View {
        Text(text)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .foregroundStyle(foreground)
            .cornerRadius(6)
    }

    /// Trimmed video error string suitable as a "we know there's no
    /// signal, don't bother spinning" trigger. Mirrors what the
    /// StatusStrip already shows in red.
    private var videoSignalError: String? {
        guard let raw = session.videoState?.error, !raw.isEmpty else { return nil }
        return raw
    }
}

/// Inline placeholder shown over the video area when the JetKVM
/// reports an HDMI-side problem (no signal, no lock, unsupported
/// mode). Frames won't be flowing, so the user gets actionable
/// guidance instead of a black window with a stalled spinner.
/// Modeled on the JetKVM web frontend's "HDMI signal error" card.
private struct NoSignalPlaceholder: View {
    let error: String

    private var humanReadableError: String {
        error.replacingOccurrences(of: "_", with: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)
            Text("HDMI signal error detected.")
                .font(.title3.bold())
            VStack(alignment: .leading, spacing: 6) {
                bullet("A loose or faulty HDMI connection")
                bullet("Incompatible resolution or refresh rate settings")
                bullet("The connected computer is powered off or asleep")
                bullet("Issues with the source device's HDMI output")
            }
            .font(.callout)
            Text(verbatim: "Reported state: \(humanReadableError)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: 460, alignment: .leading)
        .background(
            Color(NSColor.windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .shadow(radius: 16)
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(text)
        }
    }
}

private struct KVMVideoRepresentable: NSViewRepresentable {
    /// The renderer to embed, built by the active backend.
    let renderer: any KVMVideoRenderer
    let session: Session
    let pointerLocked: Bool
    let hideCursorOverVideo: Bool

    private func attach(to view: KVMVideoView) {
        view.attach(renderer: renderer)
    }

    func makeNSView(context: Context) -> KVMVideoView {
        let view = KVMVideoView()
        view.setSession(session)
        view.pointerLocked = pointerLocked
        view.hideCursorOverVideo = hideCursorOverVideo
        attach(to: view)
        return view
    }

    func updateNSView(_ nsView: KVMVideoView, context: Context) {
        nsView.setSession(session)
        nsView.pointerLocked = pointerLocked
        nsView.hideCursorOverVideo = hideCursorOverVideo
        attach(to: nsView)
        // SwiftUI re-runs updateNSView whenever observed Session
        // state changes. Tell the NSView to reconsider its
        // cursor-rect hide condition (videoState.error may have
        // appeared/cleared, or the user toggled hideCursorOverVideo
        // in the toolbar settings menu).
        nsView.refreshCursorRects()
    }

    static func dismantleNSView(_ nsView: KVMVideoView, coordinator: ()) {
        nsView.detach()
    }
}
