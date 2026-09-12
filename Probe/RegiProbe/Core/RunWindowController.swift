import AppKit
import SwiftUI

/// The run window is the shield.
///
/// Its lifetime *is* the shield's lifetime — press Start, it opens and the tap
/// begins swallowing keyboard input; press Stop, it closes and swallowing ends.
/// There is no separate armed state to fall out of sync, no TTL and no
/// heartbeat.
///
/// The two halves of "protect the target" have different answers:
///
/// - **Mouse**: the window itself is the shield. Covering the whole screen, it
///   absorbs every click onto an inert surface, so stray clicks cannot reach the
///   target's other apps. No mouse event is ever swallowed — which is precisely
///   what keeps the Stop button clickable.
/// - **Keyboard**: the tap swallows. Being key stops ordinary typing landing
///   anywhere, but ⌘Q and ⌘Tab would still fire, so key and flags events return
///   nil while this window is up.
///
/// A borderless window, deliberately **not** macOS fullscreen mode: a real
/// fullscreen space auto-hides its titlebar and its ⌘-based exits are exactly
/// what is being swallowed.
///
/// **Observe mode** drops the shield on purpose. Some bugs only appear while
/// the operator drives the target's own apps — a single click in Finder
/// opening the file, say — and a shield that swallows the keyboard and eats
/// every click makes precisely those unreproducible while the instrument that
/// would measure them is running. Observe mode shows the telemetry band alone,
/// parked in a corner, passes mouse input straight through to whatever is
/// underneath, and leaves the keyboard alone.
///
/// Nothing protects the target in that mode. It is for hand-driven
/// investigation with someone watching, never for an unattended scenario run —
/// which is why it is a separate entry point rather than a flag on Start.
@MainActor
final class RunWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: ProbeModel
    private var priorPresentationOptions: NSApplication.PresentationOptions?

    init(model: ProbeModel) {
        self.model = model
        super.init()
    }

    var isOpen: Bool { window != nil }

    func open(shielded: Bool = true) {
        guard window == nil, model.blocker == nil else { return }
        guard let screen = NSScreen.main else { return }

        // Shielded covers the screen. Observe shows only the band, top-right,
        // leaving the rest of the target usable. The band keeps its full size
        // either way — QR legibility depends on it and nothing downstream can
        // recover detail the HDMI frame never carried.
        let side = RunView.bandSide + RunView.observeChrome
        let frame = shielded
            ? screen.frame
            : NSRect(x: screen.frame.maxX - side - 16,
                     y: screen.frame.maxY - side - 16,
                     width: side, height: side)

        let w = NSWindow(contentRect: frame,
                         styleMask: [.borderless],
                         backing: .buffered,
                         defer: false,
                         screen: screen)
        w.level = .screenSaver
        w.isOpaque = true
        w.backgroundColor = .white
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]
        w.delegate = self
        // Accepts key events so ordinary typing lands here rather than in
        // whatever was focused, complementing the tap's swallowing.
        w.acceptsMouseMovedEvents = true
        // The shield absorbs clicks onto an inert surface; the observer must
        // not, or it would eat the very clicks under investigation. Visible
        // but not hit-testable, so input lands in Finder underneath.
        w.ignoresMouseEvents = !shielded

        let host = NSHostingView(rootView: RunView(model: model,
                                                   compact: !shielded,
                                                   onStop: { [weak self] in
            self?.close()
        }))
        host.frame = NSRect(origin: .zero, size: frame.size)
        w.contentView = host

        // Observe mode leaves the menu bar, the Dock and ⌘Tab alone: the
        // operator is meant to keep using the machine.
        if shielded {
            priorPresentationOptions = NSApp.presentationOptions
            NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
        }

        window = w
        w.makeKeyAndOrderFront(nil)
        // Do not steal focus in observe mode — the operator is about to click
        // in another app and taking key here would fight them for it.
        if shielded { NSApp.activate(ignoringOtherApps: true) }
        model.beginRun(shielded: shielded)
    }

    func close() {
        guard let w = window else { return }
        model.endRun()
        window = nil
        w.delegate = nil
        w.orderOut(nil)
        if let prior = priorPresentationOptions {
            NSApp.presentationOptions = prior
            priorPresentationOptions = nil
        }
    }

    func toggle() { isOpen ? close() : open() }
    func toggleObserve() { isOpen ? close() : open(shielded: false) }

    func windowWillClose(_ notification: Notification) { close() }

    /// Sleep, screen lock and session switch all end a run: the operator is
    /// gone and leaving the keyboard swallowed would be the worst outcome.
    func observeSystemEvents() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.close() }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }
}
