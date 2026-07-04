import AppKit
import Foundation
import JetKVMTransport
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "vnc-clipboard-sync")

/// Text-only NSPasteboard ↔ VNC cut-text synchronisation. One instance per KVM
/// session window, alongside (and mutually exclusive at runtime with) the
/// JetKVM agent-based `ClipboardSyncManager` — only one of the two ever finds
/// its backend surface non-nil.
///
/// Active iff the user toggle is on and the session exposes a live
/// `VNCTextClipboard`. Uses the shared `PasteboardMonitor` for local-change
/// detection, echo suppression, and the concealed-write opt-out.
@MainActor
final class VNCClipboardSyncManager {
    private let session: Session
    private let monitor = PasteboardMonitor()

    private(set) var enabled: Bool {
        didSet { reconcile() }
    }

    /// Identity of the `VNCTextClipboard` we've bound `onRemoteText` to, so we
    /// rebind across reconnects (the backend keeps one instance, but guard
    /// anyway).
    private var boundClipboardID: ObjectIdentifier?
    private var wasActive = false

    init(session: Session, initialEnabled: Bool) {
        self.session = session
        self.enabled = initialEnabled
        monitor.onLocalChange = { [weak self] pb in self?.sendLocalText(pb) }
        reconcile()
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

    /// Bind `onRemoteText` to whichever `VNCTextClipboard` the session exposes,
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
