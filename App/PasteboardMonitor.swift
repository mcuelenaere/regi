import AppKit
import Foundation

/// Watches `NSPasteboard.general` for genuine local changes and reports them
/// via `onLocalChange`. Extracted from `ClipboardSyncManager` so both the
/// JetKVM agent-based sync and the VNC text-only sync share one implementation.
///
/// macOS has no public NSPasteboard-changed notification, so this follows the
/// standard pattern: a low-rate poll plus opportunistic hot checks on
/// app/window activation (where the user has most likely just finished a copy).
/// It filters out our own applied writes (echo suppression via
/// `noteApplied(changeCount:)`) and password-manager transient writes
/// (`org.nspasteboard.ConcealedType`).
@MainActor
final class PasteboardMonitor {
    static let pollInterval: TimeInterval = 0.5

    /// macOS clipboard-utility convention: items typed as
    /// `org.nspasteboard.ConcealedType` are password-manager "transient" writes
    /// that explicitly opt out of sync. 1Password / Bitwarden / Keychain set it.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Fires for genuine, non-concealed local changes that aren't our own echo.
    var onLocalChange: ((NSPasteboard) -> Void)?

    private var pollTimer: Timer?
    private var tokens: [NSObjectProtocol] = []
    private var running = false

    /// changeCount we ourselves caused by applying remote content; the next
    /// poll skips it so we don't echo it back.
    private var lastAppliedChangeCount = NSPasteboard.general.changeCount
    /// changeCount we've already considered as a possible outbound trigger.
    private var lastObservedChangeCount = NSPasteboard.general.changeCount

    init() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.check() }
        })
        tokens.append(nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.check() }
        })
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        pollTimer?.invalidate()
    }

    func start() {
        guard !running else { return }
        running = true
        // Reset baselines so we don't immediately ship whatever's already there.
        lastObservedChangeCount = NSPasteboard.general.changeCount
        lastAppliedChangeCount = NSPasteboard.general.changeCount
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func stop() {
        running = false
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Record a changeCount we caused by applying remote content, so the next
    /// poll tick doesn't treat it as a fresh local change.
    func noteApplied(changeCount: Int) {
        lastAppliedChangeCount = changeCount
        lastObservedChangeCount = changeCount
    }

    private func check() {
        guard running else { return }
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastObservedChangeCount else { return }
        lastObservedChangeCount = count
        if count == lastAppliedChangeCount { return } // our own echo
        if let types = pb.types, types.contains(Self.concealedType) { return } // password manager
        onLocalChange?(pb)
    }
}
