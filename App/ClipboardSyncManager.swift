import AppKit
import Foundation
import JetKVMProtocol
import JetKVMTransport
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "clipboard-sync")

/// Owns the per-session bidirectional NSPasteboard ↔ `host_bridge`
/// synchronisation loop. One instance per KVM session window.
///
/// Becomes active iff:
///   - the user-facing toggle is on (`@AppStorage` "RegiClipboardSyncEnabled")
///   - `session.clipboardAgentState == .active` (a host agent is connected)
///   - the `ClipboardBridge` has been constructed for the session
///
/// When inactive the manager is fully quiescent: no timer, no
/// observers feeding it, and `inboundOffers` go undrained. The
/// bridge itself stays alive — its data-channel pump in `Session`
/// continues to decode frames; the manager just doesn't act on them.
///
/// macOS has no public NSPasteboard-changed notification, so we
/// follow the standard pattern: a low-rate poll (`pollInterval`)
/// plus opportunistic hot checks on app/window activation events
/// where the user has most likely just finished a copy.
@MainActor
final class ClipboardSyncManager {

    private let session: Session
    private let source = NSPasteboardClipboardSource()

    /// User's persisted preference, mirrored in from the view.
    /// Setter reconciles the active state.
    private(set) var enabled: Bool {
        didSet { reconcile() }
    }

    private var pollTimer: Timer?
    private var inboundTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []

    /// changeCount value we ourselves caused by applying an inbound
    /// offer; the next poll tick skips it so we don't echo back what
    /// we just received.
    private var lastAppliedInboundChangeCount: Int = NSPasteboard.general.changeCount

    /// changeCount we've already considered as a possible outbound
    /// trigger. Reset whenever the manager goes active.
    private var lastObservedChangeCount: Int = NSPasteboard.general.changeCount

    /// macOS clipboard-utility convention: items typed as
    /// `org.nspasteboard.ConcealedType` are password-manager
    /// "transient" writes that explicitly opt out of sync. We honour
    /// it on outbound — 1Password / Bitwarden / Keychain all set it.
    private static let concealedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static let pollInterval: TimeInterval = 0.5

    init(session: Session, initialEnabled: Bool) {
        self.session = session
        self.enabled = initialEnabled

        // Hot-path event taps. macOS gives us no NSPasteboard-changed
        // notification but we can opportunistically check at moments
        // the user is likely to have just copied something elsewhere.
        let nc = NotificationCenter.default
        notificationTokens.append(nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkLocalClipboard() }
        })
        notificationTokens.append(nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkLocalClipboard() }
        })

        reconcile()
    }

    deinit {
        // NotificationCenter handles main-thread removal safely.
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        pollTimer?.invalidate()
        inboundTask?.cancel()
    }

    /// Called by the view when the user flips the toggle.
    func setEnabled(_ v: Bool) {
        guard enabled != v else { return }
        enabled = v
    }

    /// Called by the view when `session.clipboardAgentState` or
    /// `session.clipboardBridge` changes (via SwiftUI `.onChange`).
    func sessionStateChanged() {
        reconcile()
    }

    // MARK: - Internal

    private var isActive: Bool {
        enabled
            && session.clipboardAgentState == .active
            && session.clipboardBridge != nil
    }

    /// Tracks whether `start()` is currently in effect so reconcile()
    /// can log on edges only — `stop()` was previously logging on
    /// every reconcile that landed in stop, including idempotent
    /// "still inactive" calls.
    private var wasActive: Bool = false

    private func reconcile() {
        let nowActive = isActive
        if nowActive == wasActive {
            // No-op transition; don't churn the log.
            return
        }
        wasActive = nowActive
        if nowActive {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard let bridge = session.clipboardBridge else { return }

        // Wire our pasteboard source into the bridge so outbound +
        // outbound-request reads find it.
        bridge.source = source

        // Reset baselines so we don't immediately ship whatever is
        // currently on the pasteboard.
        lastObservedChangeCount = NSPasteboard.general.changeCount
        lastAppliedInboundChangeCount = NSPasteboard.general.changeCount

        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.checkLocalClipboard() }
        }

        inboundTask = Task { @MainActor [weak self, weak bridge] in
            guard let bridge else { return }
            for await offer in bridge.inboundOffers {
                self?.applyInboundOffer(offer)
            }
        }

        // Initiate the Hello dance now. The bridge stays silent on
        // the wire until this — Regi is the one that decides when a
        // clipboard-sync session begins. If the channel later cycles,
        // the bridge re-Hellos on its own since it's now engaged.
        Task { @MainActor [weak bridge] in
            await bridge?.engage()
        }

        log.info("clipboard sync active")
    }

    private func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        inboundTask?.cancel()
        inboundTask = nil
        session.clipboardBridge?.source = nil
        session.clipboardBridge?.disengage()
        log.info("clipboard sync inactive")
    }


    // MARK: - Outbound (local change → host)

    private func checkLocalClipboard() {
        guard isActive else { return }
        let pb = NSPasteboard.general
        let count = pb.changeCount

        guard count != lastObservedChangeCount else { return }
        lastObservedChangeCount = count

        // Suppress the echo from our own inbound apply.
        if count == lastAppliedInboundChangeCount { return }

        // Respect the concealed-paste convention.
        if let types = pb.types, types.contains(Self.concealedPasteboardType) {
            log.debug("clipboard sync: outbound suppressed (concealed type present)")
            return
        }

        Task { @MainActor [weak self] in
            await self?.session.clipboardBridge?.sendOffer()
        }
    }

    // MARK: - Inbound (host → local)

    private func applyInboundOffer(_ offer: ResolvedOffer) {
        guard isActive else { return }
        guard !offer.formats.isEmpty else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        for format in offer.formats {
            guard let type = NSPasteboardClipboardSource.macOSType(for: format.mime) else {
                continue
            }
            pb.setData(format.data, forType: type)
        }
        let newCount = pb.changeCount
        lastAppliedInboundChangeCount = newCount
        // Move the outbound baseline too so the very next poll skips
        // the change we just made (defence in depth — the count-equals
        // check above already handles it, but a redundant skip cant hurt).
        lastObservedChangeCount = newCount

        log.debug("clipboard sync: applied inbound offer \(offer.offerId, privacy: .public) with \(offer.formats.count, privacy: .public) formats")
    }
}
