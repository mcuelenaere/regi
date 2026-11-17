// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import KVMKit
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "text-clipboard-sync")

/// Text-only NSPasteboard ↔ remote clipboard synchronisation: VNC cut text, or
/// a JetKVM's OS Services clipboard. One instance per KVM session window,
/// alongside (and mutually exclusive at runtime with) the JetKVM agent-based
/// `ClipboardSyncManager` — the session only exposes a `TextClipboard` while
/// no agent is connected.
///
/// Active iff the user toggle is on and the session exposes a live
/// `TextClipboard`. Uses the shared `PasteboardMonitor` for local-change
/// detection, echo suppression, and the concealed-write opt-out. A remote
/// that never pushes (OS Services) is read when Regi loses focus: that is
/// when the operator is about to paste what they copied over there.
@MainActor
final class TextClipboardSyncManager {
    private let session: Session
    private let monitor = PasteboardMonitor()

    private(set) var enabled: Bool {
        didSet { reconcile() }
    }

    /// Identity of the `TextClipboard` we've bound `onRemoteText` to, so we
    /// rebind across reconnects (the backend keeps one instance, but guard
    /// anyway).
    private var boundClipboardID: ObjectIdentifier?
    private var wasActive = false
    private var tokens: [NSObjectProtocol] = []

    init(session: Session, initialEnabled: Bool) {
        self.session = session
        self.enabled = initialEnabled
        monitor.onLocalChange = { [weak self] pb in self?.sendLocalText(pb) }
        let nc = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.fetchRemoteText() }
            })
        }
        reconcile()
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    /// Called by the view when the user flips the toggle.
    func setEnabled(_ v: Bool) {
        guard enabled != v else { return }
        enabled = v
    }

    /// Called by the view when session state changes (via `.onChange`).
    func sessionStateChanged() {
        reconcile()
    }

    private var isActive: Bool {
        enabled && (session.textClipboard?.isAvailable ?? false)
    }

    private func reconcile() {
        bindRemoteHandler()
        let nowActive = isActive
        guard nowActive != wasActive else { return }
        wasActive = nowActive
        if nowActive {
            monitor.start()
            log.info("VNC clipboard sync active")
        } else {
            monitor.stop()
            log.info("VNC clipboard sync inactive")
        }
    }

    /// Bind `onRemoteText` to whichever `TextClipboard` the session exposes,
    /// tracking identity so a reconnect (new surface) rebinds.
    private func bindRemoteHandler() {
        guard let clipboard = session.textClipboard else {
            boundClipboardID = nil
            return
        }
        let id = ObjectIdentifier(clipboard)
        guard id != boundClipboardID else { return }
        boundClipboardID = id
        clipboard.onRemoteText = { [weak self] text in self?.applyRemoteText(text) }
    }

    private func fetchRemoteText() {
        guard isActive else { return }
        session.textClipboard?.fetchRemoteText()
    }

    private func sendLocalText(_ pb: NSPasteboard) {
        guard isActive else { return }
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        session.textClipboard?.setLocalText(text)
    }

    private func applyRemoteText(_ text: String) {
        guard isActive else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Suppress the echo of our own write on the next poll tick.
        monitor.noteApplied(changeCount: pb.changeCount)
    }
}
