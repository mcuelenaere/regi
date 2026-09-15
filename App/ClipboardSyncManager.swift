import AppKit
import Foundation
import KVMKit
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

    /// Watches the local pasteboard (poll + activation hot-checks, echo &
    /// concealed-write suppression). Shared with the VNC sync manager.
    private let monitor = PasteboardMonitor()
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

    init(session: Session, initialEnabled: Bool) {
        self.session = session
        self.enabled = initialEnabled

        log.info("[MANAGER] init: initialEnabled=\(initialEnabled, privacy: .public) agentState=\(session.clipboardAgentState.rawValue, privacy: .public) bridge=\(session.clipboardBridge == nil ? "nil" : "set", privacy: .public) changeCount=\(NSPasteboard.general.changeCount, privacy: .public)")

        monitor.onLocalChange = { [weak self] _ in self?.checkLocalClipboard() }

        reconcile()
    }

    deinit {
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
                log.debug("[MANAGER] inboundOffers received offer_id=\(offer.clipboardId, privacy: .public) formats=\(offer.formats.count, privacy: .public)")
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
        bridge.inboundFileRoot = Self.inboundFileRoot

        // The monitor resets its own baselines on start, so we don't
        // immediately ship whatever is currently on the pasteboard.
        monitor.start()
        log.debug("[MANAGER] start: pasteboard monitor started")

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
        log.debug("[MANAGER] stop: stopping pasteboard monitor")
        monitor.stop()
        // Don't cancel inboundTask — see ensureInboundConsumer().
        // applyInboundOffer's isActive guard drops anything that
        // arrives while we're inactive.
        session.clipboardBridge?.source = nil
        session.clipboardBridge?.disengage()
        log.info("clipboard sync inactive")
    }


    // MARK: - Outbound (local change → host)

    /// Called by the pasteboard monitor for a genuine local change (echo and
    /// concealed-write filtering already applied by the monitor).
    private func checkLocalClipboard() {
        guard isActive else { return }
        log.debug("[MANAGER] checkLocalClipboard: dispatching sendOffer")
        Task { @MainActor [weak self] in
            await self?.session.clipboardBridge?.sendOffer()
        }
    }

    // MARK: - Inbound (host → local)

    private func applyInboundOffer(_ offer: ResolvedOffer) {
        guard isActive else {
            log.debug("[MANAGER] applyInboundOffer offer=\(offer.clipboardId, privacy: .public): not active; dropping (toggle off?)")
            return
        }
        guard !offer.formats.isEmpty || !offer.files.isEmpty else {
            log.debug("[MANAGER] applyInboundOffer offer=\(offer.clipboardId, privacy: .public): nothing to apply")
            return
        }

        // One pasteboard item per content-form set, plus one *promise* per
        // file. The pasteboard is target-driven the same way the wire
        // payload is: a text field reads the first item's string, Finder
        // scans every item for a file. Written in one `writeObjects` call
        // so the two kinds land as siblings on a single clipboard
        // generation.
        //
        // Each file's `public.file-url` is promised rather than present.
        // Pulling one takes as long as it takes — three seconds for
        // 12 MB on real hardware — and until the pasteboard is written
        // the user still has the *previous* clipboard, with nothing to
        // say a transfer is in flight. Declaring the type costs nothing;
        // the bytes move only if something actually pastes.
        var objects: [NSPasteboardWriting] = []
        var applied: [(mime: String, type: String, size: Int)] = []
        var dropped: [String] = []

        if !offer.formats.isEmpty {
            let item = NSPasteboardItem()
            for format in offer.formats {
                guard let type = NSPasteboardClipboardSource.macOSType(for: format.mime) else {
                    dropped.append(format.mime)
                    continue
                }
                item.setData(format.data, forType: type)
                applied.append((format.mime, type.rawValue, format.data.count))
            }
            if !applied.isEmpty { objects.append(item) }
        }
        objects.append(contentsOf: offer.files.map { promise in
            ClipboardFilePasteProvider.makeItem(for: promise) { [weak self] promise in
                guard let bridge = self?.session.clipboardBridge else {
                    throw ClipboardPromiseError.superseded
                }
                return try await bridge.fetchPromisedFile(promise)
            }
        })

        guard !objects.isEmpty else {
            log.debug("[MANAGER] applyInboundOffer offer=\(offer.clipboardId, privacy: .public): nothing mappable; leaving the pasteboard alone")
            return
        }

        let pb = NSPasteboard.general
        let beforeCount = pb.changeCount
        pb.clearContents()
        pb.writeObjects(objects)
        let newCount = pb.changeCount
        monitor.noteApplied(changeCount: newCount)

        let appliedDesc = applied.map { "\($0.mime)→\($0.type)(\($0.size))" }.joined(separator: ", ")
        let filesDesc = offer.files.map(\.fileName).joined(separator: ", ")
        let droppedDesc = dropped.joined(separator: ", ")
        log.debug("[MANAGER] applyInboundOffer offer=\(offer.clipboardId, privacy: .public): changeCount \(beforeCount, privacy: .public) → \(newCount, privacy: .public) applied=[\(appliedDesc, privacy: .public)] files=[\(filesDesc, privacy: .public)] dropped=[\(droppedDesc, privacy: .public)]")
    }

    // MARK: - Inbound file storage

    /// Where files pasted from the host land on the way through. Only
    /// files somebody actually pasted get written here — a promise the
    /// user never redeems moves no bytes at all — and what does land is a
    /// staging copy the receiving app copies out of. Caches rather than
    /// temp: the user redeems the clipboard whenever they get round to
    /// it, and a reboot clearing `/tmp` underneath them would be a
    /// surprise.
    static let inboundFileRoot: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.regi.mac", isDirectory: true)
            .appendingPathComponent("ClipboardFiles", isDirectory: true)
    }()
}
