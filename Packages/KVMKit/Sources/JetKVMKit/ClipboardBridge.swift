import Foundation
import KVMCore
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "clipboard")

/// Opaque handle identifying one point in the local clipboard's
/// history. Re-reads against the same token are guaranteed to return
/// the same bytes or fail (`nil`) — used to enforce the "offer
/// superseded" semantics of `STREAM_STATUS_UNAVAILABLE`.
///
/// In practice the App layer's NSPasteboard-backed source maps this to
/// `NSPasteboard.changeCount`.
public struct ClipboardSnapshotToken: Sendable, Equatable, Hashable {
    public let value: Int
    public init(_ value: Int) { self.value = value }
}

public struct ClipboardFormatDescriptor: Sendable {
    public let mime: String
    public let size: UInt64
    /// Present ⇒ this descriptor is a *file*, not a content form. Per the
    /// spec a file is just a named representation; the receiver is
    /// target-driven and a file target (Finder, Explorer) takes all the
    /// named ones. A file's bytes are streamed straight off disk, so its
    /// `size` comes from a `stat`, not from reading it.
    public let fileName: String?

    public init(mime: String, size: UInt64, fileName: String? = nil) {
        self.mime = mime
        self.size = size
        self.fileName = fileName
    }
}

public struct ClipboardSnapshot: Sendable {
    public let token: ClipboardSnapshotToken
    public let formats: [ClipboardFormatDescriptor]
    public init(token: ClipboardSnapshotToken, formats: [ClipboardFormatDescriptor]) {
        self.token = token
        self.formats = formats
    }
}

/// What the bridge needs from the local clipboard. Implemented by the
/// App layer (NSPasteboard-backed); injected into ClipboardBridge via
/// the `source` property.
///
/// The protocol is built around a snapshot+token model so the bridge
/// can advertise representations without holding their bytes and
/// re-read them when the peer opens a stream, falling back to
/// `STREAM_STATUS_UNAVAILABLE` if the local clipboard moved on.
public protocol ClipboardSource: Sendable {
    /// Take a snapshot of the local clipboard's currently-available
    /// formats with byte sizes. The returned token identifies this
    /// snapshot; subsequent `fetchData(mime:token:)` calls succeed iff
    /// the clipboard hasn't moved on.
    func snapshot() async -> ClipboardSnapshot

    /// Fetch one format's bytes if `token` is still current.
    /// Returns nil if the clipboard has changed since.
    func fetchData(mime: String, token: ClipboardSnapshotToken) async -> Data?

    /// Locate the file backing a *named* representation, if `token` is
    /// still current. Returns nil if the clipboard has moved on or the
    /// name isn't on it.
    ///
    /// Deliberately a URL rather than bytes: a file representation is
    /// streamed off disk a chunk at a time, so a 10 GiB file costs the
    /// same resident memory as a 10 KiB one. `fetchData` can't express
    /// that — it would have to materialize the whole thing.
    func fileURL(fileName: String, token: ClipboardSnapshotToken) async -> URL?
}

extension ClipboardSource {
    /// Sources with no files to offer get this for free.
    public func fileURL(fileName: String, token: ClipboardSnapshotToken) async -> URL? { nil }
}

public struct ResolvedFormat: Sendable, Equatable {
    public let mime: String
    public let data: Data
    public init(mime: String, data: Data) {
        self.mime = mime
        self.data = data
    }
}

/// One inbound file representation the peer has *announced* but whose
/// bytes we have not pulled. The App layer publishes it on NSPasteboard
/// as a promise and calls `ClipboardBridge.fetchPromisedFile(_:)` if and
/// when something actually asks for the file.
///
/// Deliberately not a URL: pulling a 12 MB file takes seconds, and the
/// local pasteboard must not sit on the *previous* clipboard's contents
/// for that long. Announcing costs one frame, so the pasteboard is
/// correct the instant the offer lands, and a clipboard the user never
/// pastes moves no bytes at all.
public struct ClipboardFilePromise: Sendable, Equatable {
    /// The offer this promise belongs to. A promise is only redeemable
    /// while its offer is the current one — see `ClipboardPromiseError`.
    public let clipboardId: UInt32
    /// The representation's `index` within the offer, which is how the
    /// pull names what it wants.
    public let index: UInt32
    /// The (already validated) name the peer asked for. What finally
    /// lands may carry a ` (2)` suffix if the name was taken.
    public let fileName: String
    /// Announced byte length. Advisory until the transfer verifies it.
    public let size: UInt64
    /// Advisory — a file lands as an OS file reference, not a rendered
    /// flavor. Useful for picking a UTI for the promise.
    public let mime: String

    public init(clipboardId: UInt32, index: UInt32, fileName: String, size: UInt64, mime: String) {
        self.clipboardId = clipboardId
        self.index = index
        self.fileName = fileName
        self.size = size
        self.mime = mime
    }
}

/// Why redeeming a `ClipboardFilePromise` didn't produce a file.
public enum ClipboardPromiseError: Swift.Error, Equatable {
    /// The offer carrying this promise is no longer the current one — a
    /// newer clipboard event replaced it, or the channel went down. The
    /// bytes are gone; there is nothing to retry.
    case superseded
    /// The peer answered the pull with something other than `COMPLETE`.
    /// Typically `UNAVAILABLE`: the host's clipboard moved on between
    /// announcing the file and our asking for it.
    case refused(StreamClose.Status)
    /// Local failure — no space, an unwritable landing directory, or a
    /// transfer whose length didn't match what was announced.
    case failed(String)
}

/// One inbound clipboard event delivered to the App layer. Content forms
/// arrive resolved (inlined or streamed to completion); files arrive as
/// promises, since a file is only worth moving if someone pastes it.
public struct ResolvedOffer: Sendable, Equatable {
    public let clipboardId: UInt32
    /// Content forms, in the sender's preference order.
    public let formats: [ResolvedFormat]
    /// Files, in offer order, each redeemable via
    /// `ClipboardBridge.fetchPromisedFile(_:)`.
    public let files: [ClipboardFilePromise]

    public init(clipboardId: UInt32, formats: [ResolvedFormat], files: [ClipboardFilePromise] = []) {
        self.clipboardId = clipboardId
        self.formats = formats
        self.files = files
    }
}

/// Pipes the tinypipe agent-protocol `Envelope` stream over the
/// `host_bridge` data channel into and out of a local clipboard source.
///
/// Wire-protocol concerns live here — the Hello handshake, offers, the
/// forward-only streaming layer, compression negotiation, MIME
/// filtering. The App layer plugs in its NSPasteboard-backed
/// `ClipboardSource` and subscribes to `inboundOffers`.
///
/// Shape of a transfer, per the spec's streaming layer:
///
///     offer sender   → ClipboardOffer{ clipboard_id, payload }
///     offer receiver → StreamOpen{ stream_id, ClipboardItem{ id, index } }
///     offer sender   → StreamData{ stream_id, data }  (repeated, ordered)
///     offer sender   → StreamClose{ stream_id, COMPLETE }
///
/// Small representations skip the round-trip by riding `inline` on the
/// offer. Both roles are implemented here: we pull streams for inbound
/// offers, and serve them for our own outbound offers.
///
/// Files (representations with `file_name` set) ride the same layer, but
/// inbound they are *promised* rather than pulled: an inbound offer's
/// files surface on `ResolvedOffer.files` as `ClipboardFilePromise`
/// immediately, and only `fetchPromisedFile(_:)` opens a stream and
/// writes to `inboundFileRoot`, subject to the spec's receiving rules
/// (see `ClipboardFileRules`). Pulling eagerly would hold the local
/// pasteboard on the *previous* clipboard for the length of the
/// transfer — seconds, for a file of any size — with nothing to show a
/// transfer was in flight. Outbound, files are read from disk a chunk at
/// a time and never materialized whole.
///
/// `FEATURE_DRAG_V1` is implemented in the **origin** role only: the
/// operator picks a drag up in Regi and drops it on the remote surface,
/// so we send `DragOffer` / `DragEnd` and serve the resulting `DragItem`
/// pulls. tinypipe never originates a drag (it answers any `DragItem`
/// open with `UNAVAILABLE`), so there is no proxy role to implement here.
@MainActor
public final class ClipboardBridge {
    /// Wire MIMEs we both accept inbound and ship outbound. Narrower
    /// than the spec's Async-Clipboard set on purpose: it's exactly
    /// what `NSPasteboardClipboardSource` can map in both directions,
    /// so we never open a stream for bytes we'd have to throw away.
    public static let acceptedMimes: Set<String> = [
        "text/plain",
        "text/html",
        "image/png",
        "text/uri-list",
    ]

    /// Byte budget for inline bodies on one offer. The relay caps a
    /// frame at 64 KiB (`ClipboardCodec.maxFrameBytes`); this leaves
    /// headroom for the envelope, MIME strings, and field tags. We
    /// inline greedily until it's exhausted, then stream the rest.
    public static let offerInlineBudget: Int = 62 * 1024

    /// Payload bytes per `StreamData` frame — the 64 KiB frame cap less
    /// headroom for the envelope around it.
    public static let streamChunkBytes: Int = 63 * 1024

    /// Ceiling on a single inbound *content form*. The streaming layer
    /// has no length prefix we can trust before the fact, so this caps
    /// what a misbehaving peer can make us buffer. Files aren't bound by
    /// it — they stream to disk and are bounded by
    /// `ClipboardFileRules.maxFileBytes` plus a free-space preflight.
    public static let maxInboundRepresentationBytes: Int = 64 * 1024 * 1024

    /// Most files one drag or one clipboard offer may carry. A copy of a
    /// whole directory tree would arrive as an enormous representation
    /// list; refuse rather than fan out that far. Matches tinypipe's own
    /// per-drag limit, and it matters inbound too: every accepted file
    /// holds an open descriptor for the length of its transfer.
    public static let maxFilesPerPayload: Int = 256

    /// Most drags we'll track at once. Drags are concurrent rather than
    /// superseding, and a dropped one lingers until its pulls finish, so
    /// the map needs a bound. Oldest is evicted.
    public static let maxTrackedDrags: Int = 8

    /// Temp files older than this are a previous run's debris, not a live
    /// transfer, so `sweepOrphans` may remove them.
    static let orphanMinAge: TimeInterval = 60 * 60

    /// Compress text payloads at or above this raw size when the peer
    /// advertised deflate. Smaller payloads don't compress meaningfully.
    public static let deflateMinSize: Int = 256

    /// Informational `Hello.user_agent`, like an HTTP User-Agent.
    public static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "regi/\($0)" } ?? "regi"
    }()

    /// Source for the local clipboard. App layer assigns this before
    /// the bridge can ship outbound offers. When nil, `sendOffer()` is
    /// a no-op; inbound offers still resolve and reach `inboundOffers`.
    public var source: ClipboardSource?

    /// Where inbound files land. Each offer gets its own subdirectory, so
    /// two clipboard events carrying `report.pdf` don't have to fight over
    /// the name. The App layer points this somewhere durable; the default
    /// keeps the bridge usable (and the tests hermetic) on its own.
    public var inboundFileRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("RegiClipboardFiles", isDirectory: true) {
        didSet { hasSweptFileRoot = false }
    }

    /// Distinguishes this bridge's landing directories from a previous
    /// run's. See `prepareFilesDirectory`.
    private let sessionTag = UUID().uuidString.prefix(8)
    private var hasSweptFileRoot = false

    /// What the peer's `Hello` told us they can decode. `nil` until the
    /// peer's `Hello` is parsed; sender compression defaults to `.none`
    /// in that window.
    public private(set) var peerHello: Hello?

    /// Stream of fully-resolved inbound offers. One element per agent
    /// clipboard event, with all accepted representations either
    /// inlined or streamed.
    public let inboundOffers: AsyncStream<ResolvedOffer>

    // MARK: - Internal state

    private let sendFrame: @Sendable (Data) async -> Bool
    private let inboundOffersContinuation: AsyncStream<ResolvedOffer>.Continuation

    /// `true` when the App layer has called `engage()` — the user has
    /// opted into clipboard sync for this session. The bridge stays
    /// silent on the wire until engaged: no Hello, no offers. The
    /// agent's WS to the KVM can cycle freely without producing Hello
    /// flood — only an engaged Regi initiates.
    private var isEngaged: Bool = false
    /// Mirror of the host_bridge data-channel ready state, so `engage()`
    /// and `handleChannelReadyChange(true)` can each ship the Hello
    /// whichever happens second.
    private var channelReady: Bool = false

    private var nextOutboundClipboardId: UInt32 = 1
    /// Ids for streams *we* open (pulling inbound offers). Per the
    /// spec's two-id-space rule this never collides with the peer's.
    private var nextStreamId: UInt32 = 1
    private var nextDragId: UInt32 = 1

    /// The most recently sent offer — the only one we serve stream
    /// opens against, since a new offer supersedes its predecessor.
    private var lastOutboundOffer: OutboundOffer?
    /// The in-progress inbound offer's *content forms*. Single-slot: a
    /// new inbound offer supersedes the prior one. Cleared once the offer
    /// settles onto `inboundOffers`.
    private var pendingInbound: PartialInboundOffer?
    /// The current inbound offer's *files*, announced but (mostly) not
    /// pulled. Outlives `pendingInbound`: the promises stay redeemable
    /// for as long as this offer is the peer's current clipboard.
    private var announcedFiles: AnnouncedFiles?
    /// Callers of `fetchPromisedFile` parked on a pull in flight, by
    /// representation index. More than one can queue on the same pull —
    /// AppKit asks for a promise once per destination.
    private var promiseWaiters: [UInt32: [CheckedContinuation<URL, Error>]] = [:]
    /// Where a finished pull leaves its answer for a caller that hasn't
    /// parked yet: `sendStreamOpen` suspends, and the peer's reply is
    /// handled on this same actor, so the whole transfer can complete
    /// before the caller gets to its `withCheckedThrowingContinuation`.
    private var promiseOutcomes: [UInt32: Result<URL, ClipboardPromiseError>] = [:]
    /// Streams we opened and are still receiving, keyed by stream id.
    private var inboundStreams: [UInt32: InboundStream] = [:]
    /// Streams the peer opened on us that we're still feeding.
    private var outboundStreamsInFlight: Set<UInt32> = []
    /// Subset of the above the peer has asked us to abort.
    private var cancelledOutboundStreams: Set<UInt32> = []
    /// Which drag each in-flight outbound stream is serving, so
    /// `DragEnd{CANCELLED}` can abort exactly that drag's transfers.
    private var outboundStreamDrag: [UInt32: UInt32] = [:]
    /// One task per stream the peer opened on us. Serving runs off the
    /// inbound-frame path — see `handleStreamOpen`.
    private var outboundServeTasks: [UInt32: Task<Void, Never>] = [:]
    /// Drags we originated, by `drag_id`. Concurrent, not superseding.
    private var outboundDrags: [UInt32: OutboundDrag] = [:]

    private struct OutboundOffer {
        let clipboardId: UInt32
        let token: ClipboardSnapshotToken
        /// Representation metadata by `index`, for serving stream opens.
        let representations: [UInt32: OutboundRepresentation]
    }

    private struct OutboundRepresentation {
        let mime: String
        let compression: Compression
        /// Set ⇒ this representation is a file, served from disk rather
        /// than from `fetchData`.
        let fileName: String?
        /// The `size` we announced. Only meaningful for a file: a
        /// content form's bytes are re-read whole, but a file's can
        /// change on disk without the clipboard token noticing.
        let announcedSize: UInt64
    }

    /// A drag the operator started locally and dragged onto the remote
    /// surface. We are the origin: we hold the payload and answer the
    /// proxy's pulls.
    private struct OutboundDrag {
        let dragId: UInt32
        /// Announced files by `index`. URLs are the user's own files, so
        /// "keeping the paths alive" is just keeping this entry around.
        let files: [UInt32: OutboundDragFile]
        /// nil while the operator is still dragging.
        var endStatus: DragEnd.Status?
        /// Indices whose stream has already closed, one way or another.
        var servedIndices: Set<UInt32> = []
    }

    private struct OutboundDragFile {
        let url: URL
        let name: String
        let size: UInt64
        let compression: Compression
    }

    /// Content forms only. Files don't take slots: they never hold the
    /// offer open, which is the point — the pasteboard updates as soon as
    /// the (small) content forms are in.
    private struct PartialInboundOffer {
        let clipboardId: UInt32
        /// Accepted representations in offer order, so the resolved
        /// formats keep the sender's preference order regardless of the
        /// order streams happen to complete in.
        var slots: [Slot]

        struct Slot {
            let index: UInt32
            let mime: String
            var data: Data?
            var isPending: Bool
        }

        var isSettled: Bool { !slots.contains { $0.isPending } }

        var resolvedFormats: [ResolvedFormat] {
            slots.compactMap { slot in
                guard let data = slot.data else { return nil }
                return ResolvedFormat(mime: slot.mime, data: data)
            }
        }
    }

    /// The files one inbound offer announced. Built at offer time —
    /// names validated, caps applied — but nothing on disk until
    /// `fetchPromisedFile` redeems a promise.
    private struct AnnouncedFiles {
        let clipboardId: UInt32
        /// Offer order, so `ResolvedOffer.files` matches the sender's.
        var order: [UInt32] = []
        var byIndex: [UInt32: AnnouncedFile] = [:]
        /// What we've already agreed to write for this offer. Fed to each
        /// new writer's free-space preflight so redeeming twenty promises
        /// can't pass twenty independent checks and still fill the volume.
        var reservedBytes: UInt64 = 0

        var promises: [ClipboardFilePromise] {
            order.compactMap { index in
                guard let file = byIndex[index] else { return nil }
                return ClipboardFilePromise(
                    clipboardId: clipboardId,
                    index: index,
                    fileName: file.name,
                    size: file.size,
                    mime: file.mime
                )
            }
        }
    }

    private struct AnnouncedFile {
        let name: String
        let mime: String
        let size: UInt64
        let compression: Compression
        /// A file small enough to have ridden the offer frame. Held in
        /// memory (bounded by the frame cap) rather than written out, so
        /// an offer nobody pastes still costs no disk.
        let inline: Data?
        /// Set once the bytes are on disk. A second redemption of the
        /// same promise reuses the file instead of pulling it again.
        var landedURL: URL?
        /// Non-nil while a pull is in flight.
        var streamId: UInt32?
    }

    private struct InboundStream {
        let clipboardId: UInt32
        let index: UInt32
        let compression: Compression
        let expectedSize: UInt64
        /// Content forms accumulate here; files leave it empty.
        var buffer: Data
        /// Set ⇒ a file. Releasing it unlinks the partial, which is what
        /// makes every abort path self-cleaning.
        let file: ClipboardFileWriter?
        /// Incremental inflater for a compressed file. Content forms
        /// decompress in one shot once the stream closes.
        let inflater: RawDeflateStream?
    }

    public init(send: @escaping @Sendable (Data) async -> Bool) {
        self.sendFrame = send
        var cont: AsyncStream<ResolvedOffer>.Continuation!
        self.inboundOffers = AsyncStream<ResolvedOffer> { cont = $0 }
        self.inboundOffersContinuation = cont
    }

    deinit {
        inboundOffersContinuation.finish()
    }

    // MARK: - Engagement

    /// The App layer calls this when the user opts into clipboard sync
    /// for this session (toggle on + agent present). The bridge
    /// initiates the handshake — the spec makes Hello client-initiated,
    /// so the agent stays quiet until we speak. Ships our Hello now if
    /// the channel is open, and on every subsequent channel-ready
    /// transition until `disengage()`.
    ///
    /// Idempotent.
    public func engage() async {
        if isEngaged {
            log.info("[BRIDGE] engage(): already engaged, no-op")
            return
        }
        log.info("[BRIDGE] engage(): channelReady=\(self.channelReady, privacy: .public); will \(self.channelReady ? "ship Hello now" : "defer Hello until channel ready", privacy: .public)")
        isEngaged = true
        if channelReady {
            await sendHello()
        }
    }

    /// Opposite of `engage()`. The bridge stops initiating Hello on
    /// channel readiness. Already-exchanged peer state is retained so a
    /// quick toggle-off/on doesn't waste a round trip — only a channel
    /// close clears it.
    public func disengage() {
        log.info("[BRIDGE] disengage(): was isEngaged=\(self.isEngaged, privacy: .public)")
        isEngaged = false
    }

    // MARK: - Channel lifecycle

    /// Called by the backend's pump when the `host_bridge` data
    /// channel's readyState changes. On `true` we (re-)initiate the
    /// handshake iff currently engaged; on `false` we drop all
    /// per-connection state so a reconnect starts clean.
    public func handleChannelReadyChange(_ ready: Bool) async {
        let prevReady = channelReady
        channelReady = ready
        log.info("[BRIDGE] handleChannelReadyChange: \(prevReady, privacy: .public) → \(ready, privacy: .public); isEngaged=\(self.isEngaged, privacy: .public)")
        if ready && !prevReady && isEngaged {
            log.info("[BRIDGE] shipping Hello (channel just became ready while engaged)")
            await sendHello()
        }
        if !ready {
            resetConnectionState(reason: "channel down")
            peerHello = nil
            // Don't reset nextOutboundClipboardId / nextStreamId — they
            // only have to be monotonic per sender, and the peer treats
            // a fresh Hello as a fresh id space anyway.
        }
    }

    /// Drop everything scoped to one peer session: in-flight streams,
    /// outstanding offers. Used both on channel close and on an inbound
    /// Hello (which the spec defines as a full per-connection reset).
    private func resetConnectionState(reason: String) {
        let counts = "pendingInbound=\(pendingInbound != nil) inboundStreams=\(inboundStreams.count) outboundInFlight=\(outboundStreamsInFlight.count) lastOutbound=\(lastOutboundOffer != nil) drags=\(outboundDrags.count)"
        log.info("[BRIDGE] reset (\(reason, privacy: .public)): \(counts, privacy: .public)")
        pendingInbound = nil
        // Same for the file promises: with the channel gone there is no
        // way to redeem one, so waiters are released rather than parked
        // forever.
        discardAnnouncedFiles(reason: reason)
        // Dropping the streams releases their `ClipboardFileWriter`s, which
        // unlink the partial files — the spec's "clean up on disconnect".
        inboundStreams.removeAll()
        lastOutboundOffer = nil
        outboundDrags.removeAll()
        outboundStreamDrag.removeAll()
        // Marking in-flight sends cancelled makes their loops bail at
        // the next chunk boundary instead of streaming into the void.
        cancelledOutboundStreams.formUnion(outboundStreamsInFlight)
    }

    /// Called by the backend's pump for each binary frame on
    /// `host_bridge`.
    public func handleInboundFrame(_ data: Data) async {
        log.debug("[BRIDGE] inbound frame: \(data.count, privacy: .public) bytes")
        let message: AgentMessage
        do {
            message = try ClipboardCodec.decode(data)
        } catch {
            log.error("[BRIDGE] decode failed (\(data.count, privacy: .public) bytes): \(String(describing: error), privacy: .public)")
            return
        }

        switch message {
        case .hello(let h):
            // Per spec a Hello resets all per-connection state and we
            // re-adopt the values it carries: a fresh Hello means a
            // fresh peer, since the relay never signals connect.
            log.info("[BRIDGE] inbound: hello ua='\(h.userAgent, privacy: .public)' compressions=\(h.supportedCompressions.map(\.rawValue), privacy: .public) features=\(h.supportedFeatures.map(\.rawValue), privacy: .public)")
            resetConnectionState(reason: "peer hello")
            peerHello = h

        case .clipboardOffer(let o):
            log.debug("[BRIDGE] inbound: clipboard offer id=\(o.clipboardID, privacy: .public) reps=\(o.payload.representations.count, privacy: .public)")
            await handleInboundOffer(o)

        case .streamOpen(let open):
            log.debug("[BRIDGE] inbound: stream_open id=\(open.streamID, privacy: .public)")
            await handleStreamOpen(open)

        case .streamData(let frame):
            handleStreamData(frame)

        case .streamClose(let close):
            log.debug("[BRIDGE] inbound: stream_close id=\(close.streamID, privacy: .public) status=\(close.status.rawValue, privacy: .public)")
            handleStreamClose(close)

        case .streamCancel(let cancel):
            log.debug("[BRIDGE] inbound: stream_cancel id=\(cancel.streamID, privacy: .public)")
            await handleStreamCancel(cancel)

        case .dragOffer(let d):
            // Regi is always the drag *origin* in this phase: we send
            // DragOffer, we never receive one. tinypipe doesn't originate
            // drags either, so a conforming peer won't send these.
            log.debug("[BRIDGE] inbound: drag offer id=\(d.dragID, privacy: .public) ignored (no proxy role)")

        case .dragEnd(let d):
            // DragEnd travels client→agent: the operator releases here.
            log.debug("[BRIDGE] inbound: drag end id=\(d.dragID, privacy: .public) ignored (no proxy role)")
        }
    }

    // MARK: - Outbound offers

    /// Snapshot the local clipboard and ship an offer. No-op if the
    /// handshake hasn't completed or no source is registered.
    public func sendOffer() async {
        guard let source else {
            log.debug("[BRIDGE] sendOffer: no clipboard source registered; bailing")
            return
        }
        guard peerHello != nil else {
            log.debug("[BRIDGE] sendOffer: peer hello not received yet; bailing")
            return
        }

        let snapshot = await source.snapshot()
        let formatSummary = snapshot.formats.map { "\($0.mime)(\($0.size))" }.joined(separator: ", ")
        log.debug("[BRIDGE] sendOffer: snapshot token=\(snapshot.token.value, privacy: .public) formats=[\(formatSummary, privacy: .public)]")

        let clipboardId = nextOutboundClipboardId
        nextOutboundClipboardId &+= 1

        var representations: [Representation] = []
        var metadata: [UInt32: OutboundRepresentation] = [:]
        var inlineBudget = Self.offerInlineBudget
        var nextIndex: UInt32 = 0

        for descriptor in snapshot.formats {
            // A file's MIME is informational — it lands as an OS file
            // reference, not a rendered flavor — so `acceptedMimes` (which
            // is about what NSPasteboard can map) applies to content forms
            // only. Its *name* is what has to be acceptable.
            if let fileName = descriptor.fileName {
                do {
                    _ = try ClipboardFileRules.validate(fileName: fileName)
                } catch {
                    // Check against the same rules the receiver enforces, so
                    // we never announce a transfer guaranteed to be refused.
                    log.error("[BRIDGE] sendOffer[\(clipboardId, privacy: .public)]: file '\(fileName, privacy: .public)' is not transferable: \(String(describing: error), privacy: .public)")
                    continue
                }
            } else if !Self.acceptedMimes.contains(canonicalMime(descriptor.mime)) {
                log.debug("[BRIDGE] sendOffer[\(clipboardId, privacy: .public)]: drop unaccepted MIME '\(descriptor.mime, privacy: .public)'")
                continue
            }

            let index = nextIndex
            let compression = chooseCompression(mime: descriptor.mime, size: descriptor.size)

            var rep = Representation()
            rep.index = index
            rep.mime = descriptor.mime
            rep.size = descriptor.size
            rep.compression = compression

            if let fileName = descriptor.fileName {
                rep.fileName = fileName
                // Files always stream: inlining would mean reading the file
                // during the snapshot, which is exactly what we're avoiding.
                log.debug("[BRIDGE] sendOffer[\(clipboardId, privacy: .public)]: idx=\(index, privacy: .public) file '\(fileName, privacy: .public)' size=\(descriptor.size, privacy: .public) → stream (compression=\(compression.rawValue, privacy: .public))")
                representations.append(rep)
                metadata[index] = OutboundRepresentation(
                    mime: descriptor.mime,
                    compression: compression,
                    fileName: fileName,
                    announcedSize: descriptor.size
                )
                nextIndex += 1
                continue
            }

            // Inline only when the raw bytes could plausibly fit what's
            // left of the budget. Reading is not free (it copies the
            // pasteboard contents), so skip the read outright for
            // anything obviously too big and let it stream.
            if descriptor.size <= UInt64(inlineBudget),
               let raw = await source.fetchData(mime: descriptor.mime, token: snapshot.token) {
                let (body, actual) = compressForInline(raw: raw, preferred: compression)
                if body.count <= inlineBudget {
                    rep.size = UInt64(raw.count)
                    rep.compression = actual
                    rep.inline = body
                    inlineBudget -= body.count
                    log.debug("[BRIDGE] sendOffer[\(clipboardId, privacy: .public)]: idx=\(index, privacy: .public) '\(descriptor.mime, privacy: .public)' inline raw=\(raw.count, privacy: .public) body=\(body.count, privacy: .public) compression=\(actual.rawValue, privacy: .public)")
                    representations.append(rep)
                    metadata[index] = OutboundRepresentation(mime: descriptor.mime, compression: actual, fileName: nil, announcedSize: 0)
                    nextIndex += 1
                    continue
                }
            }

            // Streamed: advertise only, keep the bytes in the source and
            // serve them when the peer opens a stream.
            log.debug("[BRIDGE] sendOffer[\(clipboardId, privacy: .public)]: idx=\(index, privacy: .public) '\(descriptor.mime, privacy: .public)' size=\(descriptor.size, privacy: .public) → stream (compression=\(compression.rawValue, privacy: .public))")
            representations.append(rep)
            metadata[index] = OutboundRepresentation(mime: descriptor.mime, compression: compression, fileName: nil, announcedSize: 0)
            nextIndex += 1
        }

        guard !representations.isEmpty else {
            log.debug("[BRIDGE] sendOffer[\(clipboardId, privacy: .public)]: snapshot had no acceptable formats; not sending")
            return
        }

        var offer = ClipboardOffer()
        offer.clipboardID = clipboardId
        var payload = Payload()
        payload.representations = representations
        offer.payload = payload

        do {
            var frame = try ClipboardCodec.encodeClipboardOffer(offer)
            if frame.count > ClipboardCodec.maxFrameBytes {
                // Belt and braces: the budget should prevent this, but a
                // pathological MIME list could still overflow. Strip the
                // inline bodies and let everything stream.
                log.error("[BRIDGE] sendOffer[\(clipboardId, privacy: .public)]: offer frame \(frame.count, privacy: .public)B exceeds cap; re-encoding with all reps streamed")
                for i in offer.payload.representations.indices {
                    offer.payload.representations[i].clearInline()
                }
                frame = try ClipboardCodec.encodeClipboardOffer(offer)
            }
            log.debug("[BRIDGE] outbound: clipboard offer id=\(clipboardId, privacy: .public) reps=\(representations.count, privacy: .public) wire=\(frame.count, privacy: .public)")
            guard await sendFrame(frame) else {
                log.error("[BRIDGE] sendOffer[\(clipboardId, privacy: .public)]: sendFrame returned false; channel may be closed")
                return
            }
            lastOutboundOffer = OutboundOffer(
                clipboardId: clipboardId,
                token: snapshot.token,
                representations: metadata
            )
        } catch {
            log.error("[BRIDGE] sendOffer[\(clipboardId, privacy: .public)]: encode failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Serving streams for our own offers

    /// Start serving a stream the peer opened, in its own task.
    ///
    /// Deliberately not inline: the backend's frame pump awaits
    /// `handleInboundFrame`, so serving an 8 GiB file here would park the
    /// pump for the whole transfer — nothing else could be decoded,
    /// including the peer's `StreamCancel` for this very stream (making
    /// the cancel polls in the serve loops dead code) and the
    /// `StreamData` of anything we're receiving at the same time.
    private func handleStreamOpen(_ open: StreamOpen) async {
        let streamId = open.streamID
        guard outboundServeTasks[streamId] == nil else {
            // Two live streams can't share an id; the opener allocates
            // them monotonically, so this is a misbehaving peer.
            log.error("[BRIDGE] stream_open \(streamId, privacy: .public): id already in flight; closing UNAVAILABLE")
            await sendStreamClose(streamId: streamId, status: .streamStatusUnavailable)
            return
        }
        outboundServeTasks[streamId] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.outboundServeTasks.removeValue(forKey: streamId) }
            switch open.source {
            case .clipboardItem(let item):
                await self.serveClipboardItem(streamId: streamId, item: item)
            case .dragItem(let item):
                await self.serveDragItem(streamId: streamId, item: item)
            case .none:
                // A source variant added after this build, or an unset oneof.
                log.debug("[BRIDGE] stream_open \(streamId, privacy: .public): unsupported source; closing UNAVAILABLE")
                await self.sendStreamClose(streamId: streamId, status: .streamStatusUnavailable)
            }
        }
    }

    /// Wait for every stream we're currently serving to finish. Tests use
    /// it to observe a transfer that `handleStreamOpen` deliberately
    /// pushed off the inbound-frame path.
    func drainOutboundStreams() async {
        while let task = outboundServeTasks.values.first {
            await task.value
        }
    }

    private func serveClipboardItem(streamId: UInt32, item: StreamOpen.ClipboardItem) async {
        guard let offer = lastOutboundOffer, offer.clipboardId == item.clipboardID else {
            let known = lastOutboundOffer?.clipboardId.description ?? "nil"
            log.debug("[BRIDGE] stream_open \(streamId, privacy: .public): clipboard_id=\(item.clipboardID, privacy: .public) is not our current offer (=\(known, privacy: .public)); closing UNAVAILABLE")
            await sendStreamClose(streamId: streamId, status: .streamStatusUnavailable)
            return
        }
        guard let rep = offer.representations[item.index] else {
            log.debug("[BRIDGE] stream_open \(streamId, privacy: .public): no representation at index \(item.index, privacy: .public); closing UNAVAILABLE")
            await sendStreamClose(streamId: streamId, status: .streamStatusUnavailable)
            return
        }
        guard let source else {
            log.error("[BRIDGE] stream_open \(streamId, privacy: .public): no clipboard source registered; closing ERROR")
            await sendStreamClose(streamId: streamId, status: .streamStatusError)
            return
        }

        if let fileName = rep.fileName {
            guard let url = await source.fileURL(fileName: fileName, token: offer.token) else {
                log.debug("[BRIDGE] stream_open \(streamId, privacy: .public): file '\(fileName, privacy: .public)' gone from the clipboard (token=\(offer.token.value, privacy: .public)); closing UNAVAILABLE")
                await sendStreamClose(streamId: streamId, status: .streamStatusUnavailable)
                return
            }
            await serveFile(
                streamId: streamId,
                url: url,
                name: fileName,
                compression: rep.compression,
                declaredSize: rep.announcedSize,
                dragId: nil
            )
            return
        }

        guard let raw = await source.fetchData(mime: rep.mime, token: offer.token) else {
            log.debug("[BRIDGE] stream_open \(streamId, privacy: .public): source raced (token=\(offer.token.value, privacy: .public)); closing UNAVAILABLE")
            await sendStreamClose(streamId: streamId, status: .streamStatusUnavailable)
            return
        }
        // Compress the representation as one stream, per its declared
        // `compression` — StreamData carries no per-frame codec.
        guard let body = compress(raw, using: rep.compression) else {
            log.error("[BRIDGE] stream_open \(streamId, privacy: .public): compression \(rep.compression.rawValue, privacy: .public) failed; closing ERROR")
            await sendStreamClose(streamId: streamId, status: .streamStatusError)
            return
        }

        outboundStreamsInFlight.insert(streamId)
        defer {
            outboundStreamsInFlight.remove(streamId)
            cancelledOutboundStreams.remove(streamId)
        }
        log.debug("[BRIDGE] stream_open \(streamId, privacy: .public): serving '\(rep.mime, privacy: .public)' raw=\(raw.count, privacy: .public) body=\(body.count, privacy: .public) compression=\(rep.compression.rawValue, privacy: .public)")

        var offset = 0
        while offset < body.count {
            if cancelledOutboundStreams.contains(streamId) {
                log.debug("[BRIDGE] stream \(streamId, privacy: .public): cancelled by peer at \(offset, privacy: .public)/\(body.count, privacy: .public)")
                await sendStreamClose(streamId: streamId, status: .streamStatusCancelled)
                return
            }
            let end = min(offset + Self.streamChunkBytes, body.count)
            let chunk = body.subdata(in: offset..<end)
            do {
                let frame = try ClipboardCodec.encodeStreamData(streamId: streamId, data: chunk)
                guard await sendFrame(frame) else {
                    log.error("[BRIDGE] stream \(streamId, privacy: .public): sendFrame failed at \(offset, privacy: .public); abandoning")
                    return
                }
            } catch {
                log.error("[BRIDGE] stream \(streamId, privacy: .public): encode failed: \(String(describing: error), privacy: .public)")
                await sendStreamClose(streamId: streamId, status: .streamStatusError)
                return
            }
            offset = end
        }

        if cancelledOutboundStreams.contains(streamId) {
            await sendStreamClose(streamId: streamId, status: .streamStatusCancelled)
            return
        }
        await sendStreamClose(streamId: streamId, status: .streamStatusComplete)
    }

    /// Serve one file representation straight off disk.
    ///
    /// Never reads the whole file: one `streamChunkBytes` slice at a time,
    /// pushed through an incremental deflater when the representation
    /// declared compression. `declaredSize`, when known, is verified
    /// against what we actually read — a file that changed under us would
    /// otherwise fail the receiver's completeness check with no
    /// explanation from our side.
    private func serveFile(
        streamId: UInt32,
        url: URL,
        name: String,
        compression: Compression,
        declaredSize: UInt64?,
        dragId: UInt32?
    ) async {
        let reader: ClipboardFileReader
        do {
            reader = try ClipboardFileReader(url: url)
        } catch {
            log.error("[BRIDGE] stream \(streamId, privacy: .public): cannot open '\(name, privacy: .public)': \(String(describing: error), privacy: .public); closing NOT_FOUND")
            await sendStreamClose(streamId: streamId, status: .streamStatusNotFound)
            if let dragId { noteDragIndexServed(dragId: dragId) }
            return
        }
        defer { reader.close() }

        var deflater: RawDeflateStream?
        if compression == .deflate {
            deflater = try? RawDeflateStream(mode: .compress)
            guard deflater != nil else {
                log.error("[BRIDGE] stream \(streamId, privacy: .public): deflate init failed; closing ERROR")
                await sendStreamClose(streamId: streamId, status: .streamStatusError)
                if let dragId { noteDragIndexServed(dragId: dragId) }
                return
            }
        }

        outboundStreamsInFlight.insert(streamId)
        if let dragId { outboundStreamDrag[streamId] = dragId }
        defer {
            outboundStreamsInFlight.remove(streamId)
            cancelledOutboundStreams.remove(streamId)
            outboundStreamDrag.removeValue(forKey: streamId)
            if let dragId { noteDragIndexServed(dragId: dragId) }
        }
        log.debug("[BRIDGE] stream \(streamId, privacy: .public): serving file '\(name, privacy: .public)' compression=\(compression.rawValue, privacy: .public)")

        /// Frames whatever the codec handed back and ships it.
        enum Emit {
            /// Keep going.
            case sent
            /// Stop and close the stream with this status.
            case stop(StreamClose.Status)
            /// The channel is gone; a close would go nowhere either.
            case channelDead
        }
        func emit(_ body: Data) async -> Emit {
            var offset = 0
            while offset < body.count {
                if cancelledOutboundStreams.contains(streamId) { return .stop(.streamStatusCancelled) }
                let end = min(offset + Self.streamChunkBytes, body.count)
                do {
                    let frame = try ClipboardCodec.encodeStreamData(
                        streamId: streamId,
                        data: body.subdata(in: offset..<end)
                    )
                    guard await sendFrame(frame) else {
                        log.error("[BRIDGE] stream \(streamId, privacy: .public): sendFrame failed; abandoning")
                        return .channelDead
                    }
                } catch {
                    log.error("[BRIDGE] stream \(streamId, privacy: .public): encode failed: \(String(describing: error), privacy: .public)")
                    return .stop(.streamStatusError)
                }
                offset = end
            }
            return .sent
        }

        var readTotal: UInt64 = 0
        while true {
            if cancelledOutboundStreams.contains(streamId) {
                await sendStreamClose(streamId: streamId, status: .streamStatusCancelled)
                return
            }
            let slice: Data
            do {
                slice = try reader.read(upTo: Self.streamChunkBytes)
            } catch {
                log.error("[BRIDGE] stream \(streamId, privacy: .public): read failed at \(readTotal, privacy: .public): \(String(describing: error), privacy: .public)")
                await sendStreamClose(streamId: streamId, status: .streamStatusIoError)
                return
            }
            if slice.isEmpty { break }
            readTotal &+= UInt64(slice.count)

            let body: Data
            if let deflater {
                do { body = try deflater.push(slice) } catch {
                    log.error("[BRIDGE] stream \(streamId, privacy: .public): deflate failed: \(String(describing: error), privacy: .public)")
                    await sendStreamClose(streamId: streamId, status: .streamStatusError)
                    return
                }
            } else {
                body = slice
            }
            switch await emit(body) {
            case .sent: break
            case .channelDead: return
            case .stop(let status):
                await sendStreamClose(streamId: streamId, status: status)
                return
            }
        }

        if let deflater {
            do {
                let tail = try deflater.finish()
                switch await emit(tail) {
                case .sent: break
                case .channelDead: return
                case .stop(let status):
                    await sendStreamClose(streamId: streamId, status: status)
                    return
                }
            } catch {
                log.error("[BRIDGE] stream \(streamId, privacy: .public): deflate finish failed: \(String(describing: error), privacy: .public)")
                await sendStreamClose(streamId: streamId, status: .streamStatusError)
                return
            }
        }

        if cancelledOutboundStreams.contains(streamId) {
            await sendStreamClose(streamId: streamId, status: .streamStatusCancelled)
            return
        }
        if let declaredSize, declaredSize != readTotal {
            // The file changed between the offer's `stat` and this pull. The
            // receiver would discard it on the length check anyway; saying so
            // is more useful than a COMPLETE it has to reject.
            log.error("[BRIDGE] stream \(streamId, privacy: .public): '\(name, privacy: .public)' changed under us (declared \(declaredSize, privacy: .public), read \(readTotal, privacy: .public)); closing IO_ERROR")
            await sendStreamClose(streamId: streamId, status: .streamStatusIoError)
            return
        }
        log.debug("[BRIDGE] stream \(streamId, privacy: .public): file '\(name, privacy: .public)' COMPLETE (\(readTotal, privacy: .public) bytes)")
        await sendStreamClose(streamId: streamId, status: .streamStatusComplete)
    }

    // MARK: - Drag origin (FEATURE_DRAG_V1)

    /// Announce a drag the operator picked up locally and moved onto the
    /// remote surface. Lazy by design: this moves no bytes: the proxy only
    /// pulls once `endDrag(_:status:)` reports `DROPPED`.
    ///
    /// Returns the `drag_id` to pass back to `endDrag`, or nil when the
    /// drag can't be announced (not engaged, peer lacks `FEATURE_DRAG_V1`,
    /// or nothing in `fileURLs` survived the checks).
    @discardableResult
    public func beginDrag(fileURLs: [URL]) async -> UInt32? {
        guard isEngaged else {
            log.debug("[BRIDGE] beginDrag: not engaged; ignoring")
            return nil
        }
        guard peerSupportsDrag else {
            log.debug("[BRIDGE] beginDrag: peer did not advertise FEATURE_DRAG_V1; ignoring")
            return nil
        }
        guard !fileURLs.isEmpty else { return nil }
        if fileURLs.count > Self.maxFilesPerPayload {
            log.error("[BRIDGE] beginDrag: \(fileURLs.count, privacy: .public) files exceeds the \(Self.maxFilesPerPayload, privacy: .public)-file cap; ignoring")
            return nil
        }

        var representations: [Representation] = []
        var files: [UInt32: OutboundDragFile] = [:]
        var index: UInt32 = 0
        for url in fileURLs {
            let name = url.lastPathComponent
            do {
                _ = try ClipboardFileRules.validate(fileName: name)
            } catch {
                log.error("[BRIDGE] beginDrag: '\(name, privacy: .public)' is not transferable: \(String(describing: error), privacy: .public)")
                continue
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let attributes, (attributes[.type] as? FileAttributeType) == .typeRegular else {
                // A directory needs recursive-copy protocol work we haven't
                // done; anything else we can't stream at all.
                log.debug("[BRIDGE] beginDrag: skipping non-regular file '\(name, privacy: .public)'")
                continue
            }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let mime = ClipboardFileRules.mime(forFileName: name)
            let compression = chooseCompression(mime: mime, size: size)

            var rep = Representation()
            rep.index = index
            rep.fileName = name
            rep.mime = mime
            rep.size = size
            rep.compression = compression
            representations.append(rep)
            files[index] = OutboundDragFile(url: url, name: name, size: size, compression: compression)
            index += 1
        }

        guard !representations.isEmpty else {
            log.debug("[BRIDGE] beginDrag: nothing announceable; ignoring")
            return nil
        }

        let dragId = nextDragId
        nextDragId &+= 1

        var offer = DragOffer()
        offer.dragID = dragId
        var payload = Payload()
        payload.representations = representations
        offer.payload = payload

        do {
            let frame = try ClipboardCodec.encode(.dragOffer(offer))
            log.info("[BRIDGE] outbound: drag offer id=\(dragId, privacy: .public) files=\(representations.count, privacy: .public) wire=\(frame.count, privacy: .public)")
            guard await sendFrame(frame) else {
                log.error("[BRIDGE] beginDrag[\(dragId, privacy: .public)]: sendFrame returned false")
                return nil
            }
        } catch {
            log.error("[BRIDGE] beginDrag[\(dragId, privacy: .public)]: encode failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        evictOldestDragIfNeeded()
        outboundDrags[dragId] = OutboundDrag(dragId: dragId, files: files, endStatus: nil)
        return dragId
    }

    /// Report the operator's release. `DROPPED` keeps the drag's files
    /// available so the proxy's `StreamOpen{DragItem}` pulls can be served;
    /// `CANCELLED` forgets it and aborts anything already in flight.
    public func endDrag(_ dragId: UInt32, status: DragEnd.Status) async {
        guard var drag = outboundDrags[dragId] else {
            log.debug("[BRIDGE] endDrag \(dragId, privacy: .public): unknown drag; ignoring")
            return
        }
        guard drag.endStatus == nil else {
            log.debug("[BRIDGE] endDrag \(dragId, privacy: .public): already ended; ignoring")
            return
        }
        drag.endStatus = status
        outboundDrags[dragId] = drag

        var end = DragEnd()
        end.dragID = dragId
        end.status = status
        do {
            let frame = try ClipboardCodec.encode(.dragEnd(end))
            log.info("[BRIDGE] outbound: drag end id=\(dragId, privacy: .public) status=\(status.rawValue, privacy: .public)")
            _ = await sendFrame(frame)
        } catch {
            log.error("[BRIDGE] endDrag[\(dragId, privacy: .public)]: encode failed: \(String(describing: error), privacy: .public)")
        }

        if status != .dragStatusDropped {
            // Cancelled (Esc, or released over no valid target): no streams
            // will open, and any already running should stop at their next
            // chunk boundary.
            for (streamId, owner) in outboundStreamDrag where owner == dragId {
                cancelledOutboundStreams.insert(streamId)
            }
            outboundDrags.removeValue(forKey: dragId)
        }
    }

    private func serveDragItem(streamId: UInt32, item: StreamOpen.DragItem) async {
        guard let drag = outboundDrags[item.dragID] else {
            log.debug("[BRIDGE] stream_open \(streamId, privacy: .public): drag \(item.dragID, privacy: .public) is not ours (or already torn down); closing UNAVAILABLE")
            await sendStreamClose(streamId: streamId, status: .streamStatusUnavailable)
            return
        }
        guard let file = drag.files[item.index] else {
            log.debug("[BRIDGE] stream_open \(streamId, privacy: .public): drag \(item.dragID, privacy: .public) has no representation at index \(item.index, privacy: .public); closing UNAVAILABLE")
            await sendStreamClose(streamId: streamId, status: .streamStatusUnavailable)
            return
        }
        // Mark the index claimed up front: a pull that never reaches its
        // `defer` (channel death) must not strand the drag forever.
        markDragIndexClaimed(dragId: item.dragID, index: item.index)
        await serveFile(
            streamId: streamId,
            url: file.url,
            name: file.name,
            compression: file.compression,
            declaredSize: file.size,
            dragId: item.dragID
        )
    }

    private func markDragIndexClaimed(dragId: UInt32, index: UInt32) {
        guard var drag = outboundDrags[dragId] else { return }
        drag.servedIndices.insert(index)
        outboundDrags[dragId] = drag
    }

    /// Forget a dropped drag once every file it announced has been pulled
    /// *and* nothing is still streaming from it. A target that takes only
    /// some of the files leaves the rest pending until the channel cycles,
    /// which `maxTrackedDrags` bounds.
    private func noteDragIndexServed(dragId: UInt32) {
        guard let drag = outboundDrags[dragId] else { return }
        guard drag.endStatus == .dragStatusDropped else { return }
        guard drag.servedIndices.count >= drag.files.count else { return }
        // Indices are claimed at open, so with concurrent pulls the last
        // index can be claimed while an earlier stream is still running.
        guard !outboundStreamDrag.values.contains(dragId) else { return }
        log.debug("[BRIDGE] drag \(dragId, privacy: .public): all \(drag.files.count, privacy: .public) file(s) pulled; forgetting")
        outboundDrags.removeValue(forKey: dragId)
    }

    private func evictOldestDragIfNeeded() {
        guard outboundDrags.count >= Self.maxTrackedDrags else { return }
        guard let oldest = outboundDrags.keys.min() else { return }
        log.error("[BRIDGE] drag table full (\(Self.maxTrackedDrags, privacy: .public)); evicting drag \(oldest, privacy: .public)")
        for (streamId, owner) in outboundStreamDrag where owner == oldest {
            cancelledOutboundStreams.insert(streamId)
        }
        outboundDrags.removeValue(forKey: oldest)
    }

    private func handleStreamCancel(_ cancel: StreamCancel) async {
        let streamId = cancel.streamID
        guard outboundStreamsInFlight.contains(streamId) || outboundServeTasks[streamId] != nil else {
            // Already finished (we sent its one StreamClose) or never
            // existed — the spec allows exactly one close per stream, so
            // stay quiet.
            log.debug("[BRIDGE] stream_cancel \(streamId, privacy: .public): not in flight; ignoring")
            return
        }
        // The serving loop notices this at its next chunk boundary and
        // emits the confirming StreamClose{CANCELLED}.
        cancelledOutboundStreams.insert(streamId)
    }

    // MARK: - Inbound offers

    private func handleInboundOffer(_ offer: ClipboardOffer) async {
        // A new offer supersedes the sender's previous one: drop pending
        // pulls and stale frames for the old clipboard_id.
        if let prior = pendingInbound, prior.clipboardId != offer.clipboardID {
            log.debug("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public) supersedes pending \(prior.clipboardId, privacy: .public)")
            await cancelInboundStreams(forClipboardId: prior.clipboardId)
        }
        // Likewise the previous offer's file promises, which outlive its
        // content forms. Anything mid-redemption is told the clipboard
        // moved on, and its partial file goes with the stream.
        for streamId in discardAnnouncedFiles(reason: "offer \(offer.clipboardID) supersedes it") {
            await sendStreamCancel(streamId: streamId)
        }

        var partial = PartialInboundOffer(clipboardId: offer.clipboardID, slots: [])
        var files = AnnouncedFiles(clipboardId: offer.clipboardID)
        var opens: [(streamId: UInt32, index: UInt32)] = []
        /// `index` is as untrusted as `file_name`. Two representations
        /// sharing one would make two slots that both resolve to the first
        /// on close, so the second could never settle and the whole offer
        /// would hang (holding its file writers open with it).
        var seenIndices: Set<UInt32> = []

        for rep in offer.payload.representations {
            guard seenIndices.insert(rep.index).inserted else {
                log.error("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): duplicate index \(rep.index, privacy: .public); skipping")
                continue
            }
            let fileName: String?
            if rep.hasFileName {
                // A file is applicable whatever its MIME — tinypipe guesses
                // it from the extension and will send anything — so
                // `acceptedMimes` (which is about what NSPasteboard can
                // render) must not gate it. The *name* is what has to pass.
                do {
                    fileName = try ClipboardFileRules.validate(fileName: rep.fileName)
                } catch {
                    log.error("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): rejecting unsafe file name: \(String(describing: error), privacy: .public)")
                    continue
                }
            } else {
                guard Self.acceptedMimes.contains(canonicalMime(rep.mime)) else {
                    log.debug("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): drop unaccepted MIME '\(rep.mime, privacy: .public)'")
                    continue
                }
                fileName = nil
            }

            if let fileName {
                // Announce only. No directory, no temp file, no
                // StreamOpen: a file costs nothing until someone pastes
                // it. Everything checkable without the bytes is checked
                // here, so we never publish a promise we couldn't redeem.
                guard files.order.count < Self.maxFilesPerPayload else {
                    log.error("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): over the \(Self.maxFilesPerPayload, privacy: .public)-file cap; ignoring the rest")
                    continue
                }
                guard rep.size <= ClipboardFileRules.maxFileBytes else {
                    log.error("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): file '\(fileName, privacy: .public)' declares \(rep.size, privacy: .public)B, over cap; skipping")
                    continue
                }
                switch rep.compression {
                case .none, .unspecified, .deflate:
                    break
                default:
                    log.error("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): file '\(fileName, privacy: .public)' uses compression \(rep.compression.rawValue, privacy: .public) we never advertised; skipping")
                    continue
                }
                files.order.append(rep.index)
                files.byIndex[rep.index] = AnnouncedFile(
                    name: fileName,
                    mime: rep.mime,
                    size: rep.size,
                    compression: rep.compression,
                    inline: rep.hasInline ? rep.inline : nil
                )
                log.debug("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): idx=\(rep.index, privacy: .public) promises file '\(fileName, privacy: .public)' size=\(rep.size, privacy: .public)\(rep.hasInline ? " (inline)" : "", privacy: .public)")
                continue
            }

            if rep.hasInline {
                // `inline` present (even empty) ⇒ apply directly.
                if let decoded = decompress(rep.inline, using: rep.compression) {
                    partial.slots.append(.init(
                        index: rep.index, mime: rep.mime, data: decoded, isPending: false
                    ))
                    log.debug("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): idx=\(rep.index, privacy: .public) inline '\(rep.mime, privacy: .public)' wire=\(rep.inline.count, privacy: .public) decoded=\(decoded.count, privacy: .public)")
                } else {
                    log.error("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): failed to decode inline '\(rep.mime, privacy: .public)'")
                }
                continue
            }

            guard rep.size <= UInt64(Self.maxInboundRepresentationBytes) else {
                log.error("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): '\(rep.mime, privacy: .public)' declares \(rep.size, privacy: .public)B, over cap; skipping")
                continue
            }

            let streamId = nextStreamId
            nextStreamId &+= 1
            inboundStreams[streamId] = InboundStream(
                clipboardId: offer.clipboardID,
                index: rep.index,
                compression: rep.compression,
                expectedSize: rep.size,
                buffer: Data(),
                file: nil,
                inflater: nil
            )
            partial.slots.append(.init(
                index: rep.index, mime: rep.mime, data: nil, isPending: true
            ))
            opens.append((streamId, rep.index))
        }

        if partial.slots.isEmpty && files.order.isEmpty {
            log.debug("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): nothing acceptable; ignoring")
            pendingInbound = nil
            return
        }

        pendingInbound = partial
        announcedFiles = files.order.isEmpty ? nil : files

        for open in opens {
            log.debug("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): opening stream \(open.streamId, privacy: .public) for idx=\(open.index, privacy: .public)")
            let sent = await sendStreamOpen(
                streamId: open.streamId,
                clipboardId: offer.clipboardID,
                index: open.index
            )
            guard !sent else { continue }
            // The peer never learned of the pull, so no StreamData or
            // StreamClose is coming: resolve the slot now rather than
            // leave the offer pending forever.
            log.error("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): stream_open \(open.streamId, privacy: .public) did not go out; failing idx=\(open.index, privacy: .public)")
            inboundStreams.removeValue(forKey: open.streamId)
            failInboundSlot(index: open.index, clipboardId: offer.clipboardID)
        }

        // An offer whose content forms all rode inline — including one
        // that is nothing but files — settles right here, which is the
        // whole point: the pasteboard is correct one frame after the
        // offer, not one transfer later.
        settleIfComplete()
    }

    // MARK: - Redeeming file promises

    /// Pull one announced file and return where it landed.
    ///
    /// Called when something actually asks for the file — AppKit
    /// fulfilling an `NSFilePromiseProvider` the App layer put on the
    /// pasteboard — which is what keeps a copy the user never pastes off
    /// the wire and off the disk. Everything the spec requires of a
    /// receiver still happens here, just later: validated name, hidden
    /// temp file in the destination directory, incremental size
    /// enforcement, `O_EXCL` claim, atomic rename.
    ///
    /// Idempotent per promise: the second caller for a file already on
    /// disk gets the same URL, and callers arriving mid-pull queue on it
    /// rather than starting a second transfer.
    public func fetchPromisedFile(_ promise: ClipboardFilePromise) async throws -> URL {
        guard let current = announcedFiles, current.clipboardId == promise.clipboardId,
              let file = current.byIndex[promise.index]
        else {
            log.debug("[BRIDGE] promise \(promise.clipboardId, privacy: .public)/\(promise.index, privacy: .public) '\(promise.fileName, privacy: .public)': offer is no longer current")
            throw ClipboardPromiseError.superseded
        }
        if let landed = file.landedURL {
            log.debug("[BRIDGE] promise \(promise.clipboardId, privacy: .public)/\(promise.index, privacy: .public): already on disk at \(landed.lastPathComponent, privacy: .public)")
            return landed
        }
        if file.streamId != nil {
            // Someone got here first; ride their transfer.
            return try await withCheckedThrowingContinuation { continuation in
                promiseWaiters[promise.index, default: []].append(continuation)
            }
        }

        guard let directory = prepareFilesDirectory(clipboardId: promise.clipboardId) else {
            throw ClipboardPromiseError.failed("no landing directory")
        }
        // Creating the writer *is* the preflight: it re-validates the
        // name, rejects an implausible size, checks free space against
        // what this offer has already claimed, and claims a temp file.
        let writer: ClipboardFileWriter
        do {
            writer = try ClipboardFileWriter(
                directory: directory,
                rawName: file.name,
                declaredSize: file.size,
                alreadyReserved: current.reservedBytes
            )
        } catch {
            log.error("[BRIDGE] promise \(promise.clipboardId, privacy: .public)/\(promise.index, privacy: .public): cannot accept '\(file.name, privacy: .public)': \(String(describing: error), privacy: .public)")
            throw ClipboardPromiseError.failed(String(describing: error))
        }
        announcedFiles?.reservedBytes = current.reservedBytes
            .addingReportingOverflow(file.size).partialValue

        // A tiny file rode the offer frame; it still has to reach the
        // disk, since what we hand back is a file reference.
        if let inline = file.inline {
            guard let decoded = decompress(inline, using: file.compression),
                  let url = commit(writer: writer, bytes: decoded, name: file.name)
            else {
                throw ClipboardPromiseError.failed("could not materialize inlined file '\(file.name)'")
            }
            announcedFiles?.byIndex[promise.index]?.landedURL = url
            return url
        }

        var inflater: RawDeflateStream?
        if file.compression == .deflate {
            inflater = try? RawDeflateStream(mode: .decompress)
            guard inflater != nil else {
                writer.discard()
                throw ClipboardPromiseError.failed("inflate init failed for '\(file.name)'")
            }
        }

        let streamId = nextStreamId
        nextStreamId &+= 1
        promiseOutcomes.removeValue(forKey: promise.index)
        inboundStreams[streamId] = InboundStream(
            clipboardId: promise.clipboardId,
            index: promise.index,
            compression: file.compression,
            expectedSize: file.size,
            buffer: Data(),
            file: writer,
            inflater: inflater
        )
        announcedFiles?.byIndex[promise.index]?.streamId = streamId

        log.info("[BRIDGE] promise \(promise.clipboardId, privacy: .public)/\(promise.index, privacy: .public): pulling '\(file.name, privacy: .public)' (\(file.size, privacy: .public)B) on stream \(streamId, privacy: .public)")
        guard await sendStreamOpen(
            streamId: streamId,
            clipboardId: promise.clipboardId,
            index: promise.index
        ) else {
            log.error("[BRIDGE] promise \(promise.clipboardId, privacy: .public)/\(promise.index, privacy: .public): stream_open \(streamId, privacy: .public) did not go out")
            inboundStreams.removeValue(forKey: streamId)
            writer.discard()
            finishPromise(index: promise.index, result: .failure(.failed("stream_open did not reach the wire")))
            promiseOutcomes.removeValue(forKey: promise.index)
            throw ClipboardPromiseError.failed("stream_open did not reach the wire")
        }
        // `sendStreamOpen` suspends, and the peer's whole answer is
        // handled on this actor — so the transfer may already be over.
        if let outcome = promiseOutcomes.removeValue(forKey: promise.index) {
            return try outcome.get()
        }
        // …or the offer may have been superseded in that same window, in
        // which case there is no longer anything that would resume us.
        guard announcedFiles?.clipboardId == promise.clipboardId,
              announcedFiles?.byIndex[promise.index]?.streamId == streamId
        else {
            log.debug("[BRIDGE] promise \(promise.clipboardId, privacy: .public)/\(promise.index, privacy: .public): offer went away while the pull was opening")
            throw ClipboardPromiseError.superseded
        }
        return try await withCheckedThrowingContinuation { continuation in
            promiseWaiters[promise.index, default: []].append(continuation)
        }
    }

    /// Hand one pull's result to everyone waiting on it, and remember it
    /// for a caller that hasn't parked yet.
    private func finishPromise(index: UInt32, result: Result<URL, ClipboardPromiseError>) {
        guard announcedFiles?.byIndex[index] != nil else { return }
        announcedFiles?.byIndex[index]?.streamId = nil
        if case .success(let url) = result {
            announcedFiles?.byIndex[index]?.landedURL = url
        }
        promiseOutcomes[index] = result
        for continuation in promiseWaiters.removeValue(forKey: index) ?? [] {
            continuation.resume(with: result)
        }
    }

    /// Forget the current offer's file promises: nobody can redeem them
    /// any more, so anything mid-pull is abandoned (which unlinks its
    /// partial file) and anyone waiting is told the clipboard moved on.
    ///
    /// Returns the stream ids that were in flight, so a caller that still
    /// has a channel can cancel them on the wire.
    @discardableResult
    private func discardAnnouncedFiles(reason: String) -> [UInt32] {
        guard let current = announcedFiles else { return [] }
        var doomed: [UInt32] = []
        for (_, file) in current.byIndex {
            guard let streamId = file.streamId else { continue }
            // Dropping the stream releases its `ClipboardFileWriter`,
            // which unlinks the partial. It may already be gone — a
            // caller that cancelled it first shouldn't get a second
            // StreamCancel out of us.
            guard inboundStreams.removeValue(forKey: streamId) != nil else { continue }
            doomed.append(streamId)
        }
        announcedFiles = nil
        promiseOutcomes.removeAll()
        let waiters = promiseWaiters.values.flatMap { $0 }
        promiseWaiters.removeAll()
        if !current.byIndex.isEmpty {
            log.debug("[BRIDGE] dropping \(current.byIndex.count, privacy: .public) file promise(s) of offer \(current.clipboardId, privacy: .public): \(reason, privacy: .public)")
        }
        for continuation in waiters {
            continuation.resume(throwing: ClipboardPromiseError.superseded)
        }
        return doomed
    }

    /// Per-offer landing directory. Each clipboard event gets its own, so
    /// two events carrying `report.pdf` don't have to disambiguate against
    /// each other, and a crashed run's debris gets swept on the way in.
    private func prepareFilesDirectory(clipboardId: UInt32) -> URL? {
        sweepOrphansOnce()
        let directory = filesDirectory(forClipboardId: clipboardId)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log.error("[BRIDGE] cannot create \(directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
        return directory
    }

    /// Where one offer's files land.
    ///
    /// Keyed by our own session tag as well as the peer's `clipboard_id`:
    /// those restart at 1 on every reconnect, so without the tag a
    /// long-lived cache directory would accumulate `report (2).pdf` …
    /// `report (999).pdf` in one folder and eventually run out of names.
    func filesDirectory(forClipboardId clipboardId: UInt32) -> URL {
        inboundFileRoot.appendingPathComponent(
            "\(sessionTag)-clipboard-\(clipboardId)", isDirectory: true
        )
    }

    /// Clear temp files a previous run's hard kill left behind — its
    /// `ClipboardFileWriter`s never got to unlink them. Walks the whole
    /// root, since the directory we're about to create is by definition
    /// empty; done once per bridge, on the first offer that carries a file.
    private func sweepOrphansOnce() {
        guard !hasSweptFileRoot else { return }
        hasSweptFileRoot = true
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(
            at: inboundFileRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        )) ?? []
        var removed = ClipboardFileRules.sweepOrphans(in: inboundFileRoot, olderThan: Self.orphanMinAge)
        for child in children {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            guard isDirectory == true else { continue }
            removed += ClipboardFileRules.sweepOrphans(in: child, olderThan: Self.orphanMinAge)
        }
        if removed > 0 {
            log.info("[BRIDGE] swept \(removed, privacy: .public) orphaned partial file(s) under \(self.inboundFileRoot.path, privacy: .public)")
        }
    }

    /// Write an already-decoded body through `writer` and commit it.
    private func commit(writer: ClipboardFileWriter, bytes: Data, name: String) -> URL? {
        do {
            try writer.write(bytes)
            return try writer.commit()
        } catch {
            log.error("[BRIDGE] file '\(name, privacy: .public)': \(String(describing: error), privacy: .public)")
            writer.discard()
            return nil
        }
    }

    private func handleStreamData(_ frame: StreamData) {
        guard var stream = inboundStreams[frame.streamID] else {
            log.debug("[BRIDGE] stream_data \(frame.streamID, privacy: .public): unknown/stale stream; dropping \(frame.data.count, privacy: .public)B")
            return
        }

        if let writer = stream.file {
            // Files never buffer: inflate (if any) and append straight to
            // the temp file, which enforces the declared size incrementally.
            do {
                let body: Data
                if let inflater = stream.inflater {
                    body = try inflater.push(frame.data)
                } else {
                    body = frame.data
                }
                try writer.write(body)
            } catch {
                log.error("[BRIDGE] stream_data \(frame.streamID, privacy: .public): file '\(writer.requestedName, privacy: .public)' failed: \(String(describing: error), privacy: .public); cancelling")
                inboundStreams.removeValue(forKey: frame.streamID)
                writer.discard()
                if announcedFiles?.clipboardId == stream.clipboardId {
                    finishPromise(index: stream.index, result: .failure(.failed(String(describing: error))))
                }
                let streamId = frame.streamID
                Task { @MainActor [weak self] in await self?.sendStreamCancel(streamId: streamId) }
            }
            return
        }

        guard stream.buffer.count + frame.data.count <= Self.maxInboundRepresentationBytes else {
            log.error("[BRIDGE] stream_data \(frame.streamID, privacy: .public): exceeds \(Self.maxInboundRepresentationBytes, privacy: .public)B cap; cancelling")
            inboundStreams.removeValue(forKey: frame.streamID)
            failInboundSlot(index: stream.index, clipboardId: stream.clipboardId)
            let streamId = frame.streamID
            Task { @MainActor [weak self] in await self?.sendStreamCancel(streamId: streamId) }
            return
        }
        stream.buffer.append(frame.data)
        inboundStreams[frame.streamID] = stream
    }

    private func handleStreamClose(_ close: StreamClose) {
        guard let stream = inboundStreams.removeValue(forKey: close.streamID) else {
            log.debug("[BRIDGE] stream_close \(close.streamID, privacy: .public): unknown/stale stream; ignoring")
            return
        }

        // A file stream is a redeemed promise, not a slot of the pending
        // offer — by now that offer has usually settled and gone.
        if let writer = stream.file {
            guard announcedFiles?.clipboardId == stream.clipboardId else {
                log.debug("[BRIDGE] stream_close \(close.streamID, privacy: .public): offer \(stream.clipboardId, privacy: .public) is no longer current; discarding partial")
                writer.discard()
                return
            }
            guard close.status == .streamStatusComplete else {
                log.debug("[BRIDGE] stream \(close.streamID, privacy: .public): file '\(writer.requestedName, privacy: .public)' closed status=\(close.status.rawValue, privacy: .public); discarding partial")
                writer.discard()
                finishPromise(index: stream.index, result: .failure(.refused(close.status)))
                return
            }
            do {
                // Flush the inflater's tail, then let `commit` do the
                // length check and the atomic move into place.
                if let inflater = stream.inflater {
                    try writer.write(try inflater.finish())
                }
                let url = try writer.commit()
                log.info("[BRIDGE] stream \(close.streamID, privacy: .public): file '\(writer.requestedName, privacy: .public)' landed at \(url.lastPathComponent, privacy: .public)")
                finishPromise(index: stream.index, result: .success(url))
            } catch {
                log.error("[BRIDGE] stream \(close.streamID, privacy: .public): file '\(writer.requestedName, privacy: .public)' not published: \(String(describing: error), privacy: .public)")
                writer.discard()
                finishPromise(index: stream.index, result: .failure(.failed(String(describing: error))))
            }
            return
        }

        guard var partial = pendingInbound, partial.clipboardId == stream.clipboardId else {
            log.debug("[BRIDGE] stream_close \(close.streamID, privacy: .public): offer \(stream.clipboardId, privacy: .public) no longer pending; ignoring")
            return
        }
        guard let slotIdx = partial.slots.firstIndex(where: { $0.index == stream.index }) else { return }

        switch close.status {
        case .streamStatusComplete:
            if let decoded = decompress(stream.buffer, using: stream.compression) {
                if decoded.count != Int(stream.expectedSize) {
                    // The spec has the receiver verify decompressed
                    // length against the representation's `size`.
                    log.error("[BRIDGE] stream \(close.streamID, privacy: .public): size mismatch (declared \(stream.expectedSize, privacy: .public), got \(decoded.count, privacy: .public)); dropping")
                    partial.slots[slotIdx].isPending = false
                } else {
                    partial.slots[slotIdx].data = decoded
                    partial.slots[slotIdx].isPending = false
                    log.debug("[BRIDGE] stream \(close.streamID, privacy: .public): COMPLETE idx=\(stream.index, privacy: .public) wire=\(stream.buffer.count, privacy: .public) decoded=\(decoded.count, privacy: .public)")
                }
            } else {
                log.error("[BRIDGE] stream \(close.streamID, privacy: .public): decompression failed; dropping representation")
                partial.slots[slotIdx].isPending = false
            }
        default:
            log.debug("[BRIDGE] stream \(close.streamID, privacy: .public): closed status=\(close.status.rawValue, privacy: .public); dropping representation")
            partial.slots[slotIdx].isPending = false
        }

        pendingInbound = partial
        settleIfComplete()
    }

    /// Mark one representation of the pending offer as failed (no data).
    private func failInboundSlot(index: UInt32, clipboardId: UInt32) {
        guard var partial = pendingInbound, partial.clipboardId == clipboardId,
              let slotIdx = partial.slots.firstIndex(where: { $0.index == index })
        else { return }
        partial.slots[slotIdx].isPending = false
        pendingInbound = partial
        settleIfComplete()
    }

    /// Yield the pending offer once every representation has either
    /// resolved or failed.
    private func settleIfComplete() {
        guard let partial = pendingInbound, partial.isSettled else { return }
        pendingInbound = nil
        let formats = partial.resolvedFormats
        let files = announcedFiles?.clipboardId == partial.clipboardId
            ? (announcedFiles?.promises ?? [])
            : []
        log.debug("[BRIDGE] inbound offer \(partial.clipboardId, privacy: .public): settled with \(formats.count, privacy: .public) content form(s) of \(partial.slots.count, privacy: .public) + \(files.count, privacy: .public) promised file(s); yielding")
        inboundOffersContinuation.yield(
            ResolvedOffer(clipboardId: partial.clipboardId, formats: formats, files: files)
        )
    }

    private func cancelInboundStreams(forClipboardId clipboardId: UInt32) async {
        let doomed = inboundStreams.filter { $0.value.clipboardId == clipboardId }.map(\.key)
        for streamId in doomed {
            inboundStreams.removeValue(forKey: streamId)
            await sendStreamCancel(streamId: streamId)
        }
    }

    // MARK: - Compression

    /// Best mutually-supported algorithm for a representation. We can
    /// only encode NONE and DEFLATE, so that's the whole ladder; the
    /// peer's ZSTD/BROTLI support (if any) goes unused.
    private func chooseCompression(mime: String, size: UInt64) -> Compression {
        guard peerSupportsDeflate,
              isTextMime(mime),
              size >= UInt64(Self.deflateMinSize)
        else { return .none }
        return .deflate
    }

    /// Compress an inline body, downgrading to `.none` when the codec
    /// doesn't actually shrink it. Only inline bodies get this second
    /// guess — a streamed representation's `compression` is fixed by the
    /// offer before we've read its bytes.
    private func compressForInline(raw: Data, preferred: Compression) -> (Data, Compression) {
        guard preferred != .none, let body = compress(raw, using: preferred) else {
            return (raw, .none)
        }
        return body.count < raw.count ? (body, preferred) : (raw, .none)
    }

    private func compress(_ raw: Data, using compression: Compression) -> Data? {
        switch compression {
        case .none, .unspecified:
            return raw
        case .deflate:
            do {
                return try RawDeflate.compress(raw)
            } catch {
                log.error("[BRIDGE] deflate failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        case .zstd, .brotli:
            log.error("[BRIDGE] compress: \(compression.rawValue, privacy: .public) not implemented")
            return nil
        case .UNRECOGNIZED(let n):
            log.error("[BRIDGE] compress: unknown compression \(n, privacy: .public)")
            return nil
        }
    }

    /// Inverse of `compress`. An unknown numeric value is a decode
    /// failure for that representation, per spec.
    private func decompress(_ data: Data, using compression: Compression) -> Data? {
        switch compression {
        case .none, .unspecified:
            return data
        case .deflate:
            do {
                return try RawDeflate.decompress(data)
            } catch {
                log.error("[BRIDGE] inflate failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        case .zstd, .brotli:
            log.error("[BRIDGE] decompress: \(compression.rawValue, privacy: .public) not supported (we never advertise it)")
            return nil
        case .UNRECOGNIZED(let n):
            log.error("[BRIDGE] decompress: unknown compression \(n, privacy: .public); dropping")
            return nil
        }
    }

    private var peerSupportsDeflate: Bool {
        peerHello?.supportedCompressions.contains(.deflate) ?? false
    }

    /// A sender MUST NOT send a feature-gated message the peer's latest
    /// Hello didn't advertise, so `DragOffer` waits on this.
    private var peerSupportsDrag: Bool {
        peerHello?.supportedFeatures.contains(.dragV1) ?? false
    }

    private func isTextMime(_ mime: String) -> Bool {
        let canon = canonicalMime(mime)
        return canon == "text/plain" || canon == "text/html" || canon == "text/uri-list"
    }

    /// Normalize a wire MIME to its set-membership form. `text/plain`
    /// and `text/plain;charset=utf-8` both collapse to `text/plain`.
    private func canonicalMime(_ mime: String) -> String {
        let lower = mime.lowercased()
        if let semicolon = lower.firstIndex(of: ";") {
            return String(lower[..<semicolon]).trimmingCharacters(in: .whitespaces)
        }
        return lower
    }

    // MARK: - Frame senders

    private func sendHello() async {
        do {
            let frame = try ClipboardCodec.encodeHello(
                userAgent: Self.userAgent,
                compressions: [.none, .deflate],
                features: [.clipboardV1, .dragV1]
            )
            log.debug("[BRIDGE] outbound: hello ua='\(Self.userAgent, privacy: .public)' compressions=[none, deflate] features=[clipboardV1, dragV1] wire=\(frame.count, privacy: .public)")
            _ = await sendFrame(frame)
        } catch {
            log.error("[BRIDGE] sendHello: encode failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Returns whether the open actually reached the wire — a pull the
    /// peer never saw will never be answered.
    private func sendStreamOpen(streamId: UInt32, clipboardId: UInt32, index: UInt32) async -> Bool {
        do {
            let frame = try ClipboardCodec.encodeClipboardStreamOpen(
                streamId: streamId,
                clipboardId: clipboardId,
                index: index
            )
            return await sendFrame(frame)
        } catch {
            log.error("[BRIDGE] sendStreamOpen: encode failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func sendStreamClose(streamId: UInt32, status: StreamClose.Status) async {
        do {
            let frame = try ClipboardCodec.encodeStreamClose(streamId: streamId, status: status)
            log.debug("[BRIDGE] outbound: stream_close id=\(streamId, privacy: .public) status=\(status.rawValue, privacy: .public)")
            _ = await sendFrame(frame)
        } catch {
            log.error("[BRIDGE] sendStreamClose: encode failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func sendStreamCancel(streamId: UInt32) async {
        do {
            let frame = try ClipboardCodec.encodeStreamCancel(streamId: streamId)
            log.debug("[BRIDGE] outbound: stream_cancel id=\(streamId, privacy: .public)")
            _ = await sendFrame(frame)
        } catch {
            log.error("[BRIDGE] sendStreamCancel: encode failed: \(String(describing: error), privacy: .public)")
        }
    }
}
