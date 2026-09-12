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

    func open() {
        guard window == nil, model.blocker == nil else { return }
        guard let screen = NSScreen.main else { return }

        let w = NSWindow(contentRect: screen.frame,
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

        let host = NSHostingView(rootView: RunView(model: model, onStop: { [weak self] in
            self?.close()
        }))
        host.frame = screen.frame
        w.contentView = host

        priorPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]

        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.beginRun()
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
