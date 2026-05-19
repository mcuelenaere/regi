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
    /// Long-lived inbound-offer consumer task. Spawned once per
    /// `ClipboardBridge` instance (tracked via `inboundTaskBridgeID`),
    /// not per start/stop cycle: `AsyncStream<T>` is single-iteration
    /// in practice — creating a fresh iterator after the first one
    /// gets dropped (e.g. by Task cancellation) yields `nil` on the
    /// first `next()` and the loop exits immediately. So we let the
    /// consumer run for the bridge's whole lifetime and rely on
    /// `applyInboundOffer`'s isActive gate to drop offers while the
    /// manager is inactive.
    private var inboundTask: Task<Void, Never>?
    private var inboundTaskBridgeID: ObjectIdentifier?
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

        log.info("[MANAGER] init: initialEnabled=\(initialEnabled, privacy: .public) agentState=\(session.clipboardAgentState.rawValue, privacy: .public) bridge=\(session.clipboardBridge == nil ? "nil" : "set", privacy: .public) changeCount=\(NSPasteboard.general.changeCount, privacy: .public)")

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
        guard enabled != v else {
            log.debug("[MANAGER] setEnabled(\(v, privacy: .public)): no change")
            return
        }
        log.info("[MANAGER] setEnabled: \(self.enabled, privacy: .public) → \(v, privacy: .public)")
        enabled = v
    }

    /// Called by the view when `session.clipboardAgentState` or
    /// `session.clipboardBridge` changes (via SwiftUI `.onChange`).
    func sessionStateChanged() {
        log.info("[MANAGER] sessionStateChanged: agentState=\(self.session.clipboardAgentState.rawValue, privacy: .public) bridge=\(self.session.clipboardBridge == nil ? "nil" : "set", privacy: .public)")
        ensureInboundConsumer()
        reconcile()
    }

    /// Ensure we have a running inbound-offers consumer for whichever
    /// `ClipboardBridge` the session currently exposes. Cheap to call
    /// repeatedly — only spawns when the bridge identity changes
    /// (typically session reconnect). The consumer outlives start/stop
    /// cycles: `applyInboundOffer` drops anything that arrives while
    /// the manager is inactive.
    private func ensureInboundConsumer() {
        let currentBridge = session.clipboardBridge
        let currentID = currentBridge.map { ObjectIdentifier($0) }
        if currentID == inboundTaskBridgeID, inboundTask != nil {
            return
        }
        inboundTask?.cancel()
        inboundTask = nil
        inboundTaskBridgeID = nil
        guard let bridge = currentBridge else { return }
        inboundTaskBridgeID = ObjectIdentifier(bridge)
        inboundTask = Task { @MainActor [weak self, weak bridge] in
            guard let bridge else { return }
            log.info("[MANAGER] inboundOffers consumer task starting (new bridge)")
            for await offer in bridge.inboundOffers {
                log.debug("[MANAGER] inboundOffers received offer_id=\(offer.offerId, privacy: .public) formats=\(offer.formats.count, privacy: .public)")
                self?.applyInboundOffer(offer)
            }
            log.info("[MANAGER] inboundOffers consumer task ended (bridge gone)")
        }
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
        log.debug("[MANAGER] reconcile: enabled=\(self.enabled, privacy: .public) agentState=\(self.session.clipboardAgentState.rawValue, privacy: .public) bridge=\(self.session.clipboardBridge == nil ? "nil" : "set", privacy: .public) → nowActive=\(nowActive, privacy: .public) wasActive=\(self.wasActive, privacy: .public)")
        if nowActive == wasActive {
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
        guard let bridge = session.clipboardBridge else {
            log.error("[MANAGER] start: bridge is nil; can't start")
            return
        }
        log.info("[MANAGER] start: wiring source, baseline changeCount=\(NSPasteboard.general.changeCount, privacy: .public)")

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
        log.debug("[MANAGER] start: poll timer started (\(Self.pollInterval, privacy: .public)s)")

        // The inbound-offers consumer task is owned by
        // `ensureInboundConsumer()` (per-bridge lifetime). Don't
        // (re)spawn here — re-iterating an AsyncStream after task
        // cancellation yields nil on the first .next() and the loop
        // exits, which would silently break inbound apply on toggle
        // off/on cycles.

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
        log.debug("[MANAGER] stop: tearing down poll timer")
        pollTimer?.invalidate()
        pollTimer = nil
        // Don't cancel inboundTask — see ensureInboundConsumer().
        // applyInboundOffer's isActive guard drops anything that
        // arrives while we're inactive.
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
        log.debug("[MANAGER] checkLocalClipboard: changeCount advanced \(self.lastObservedChangeCount, privacy: .public) → \(count, privacy: .public)")
        lastObservedChangeCount = count

        // Suppress the echo from our own inbound apply.
        if count == lastAppliedInboundChangeCount {
            log.debug("[MANAGER] checkLocalClipboard: \(count, privacy: .public) matches lastAppliedInboundChangeCount; suppressing echo")
            return
        }

        // Respect the concealed-paste convention.
        if let types = pb.types, types.contains(Self.concealedPasteboardType) {
            log.debug("[MANAGER] checkLocalClipboard: outbound suppressed (concealed type present)")
            return
        }

        let types = (pb.types ?? []).map(\.rawValue).joined(separator: ",")
        log.debug("[MANAGER] checkLocalClipboard: dispatching sendOffer (types=[\(types, privacy: .public)])")
        Task { @MainActor [weak self] in
            await self?.session.clipboardBridge?.sendOffer()
        }
    }

    // MARK: - Inbound (host → local)

    private func applyInboundOffer(_ offer: ResolvedOffer) {
        guard isActive else {
            log.debug("[MANAGER] applyInboundOffer offer=\(offer.offerId, privacy: .public): not active; dropping (toggle off?)")
            return
        }
        guard !offer.formats.isEmpty else {
            log.debug("[MANAGER] applyInboundOffer offer=\(offer.offerId, privacy: .public): no formats to apply")
            return
        }

        let pb = NSPasteboard.general
        let beforeCount = pb.changeCount
        pb.clearContents()
        var applied: [(mime: String, type: String, size: Int)] = []
        var dropped: [String] = []
        for format in offer.formats {
            guard let type = NSPasteboardClipboardSource.macOSType(for: format.mime) else {
                dropped.append(format.mime)
                continue
            }
            pb.setData(format.data, forType: type)
            applied.append((format.mime, type.rawValue, format.data.count))
        }
        let newCount = pb.changeCount
        lastAppliedInboundChangeCount = newCount
        lastObservedChangeCount = newCount

        let appliedDesc = applied.map { "\($0.mime)→\($0.type)(\($0.size))" }.joined(separator: ", ")
        let droppedDesc = dropped.joined(separator: ", ")
        log.debug("[MANAGER] applyInboundOffer offer=\(offer.offerId, privacy: .public): changeCount \(beforeCount, privacy: .public) → \(newCount, privacy: .public) applied=[\(appliedDesc, privacy: .public)] dropped=[\(droppedDesc, privacy: .public)]")
    }
}
