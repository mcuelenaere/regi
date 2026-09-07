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
    public init(mime: String, size: UInt64) {
        self.mime = mime
        self.size = size
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
}

public struct ResolvedFormat: Sendable, Equatable {
    public let mime: String
    public let data: Data
    public init(mime: String, data: Data) {
        self.mime = mime
        self.data = data
    }
}

/// One inbound clipboard event delivered to the App layer with every
/// representation either inlined or streamed to completion. Drives the
/// "host clipboard just changed; here's what's on it" UI flow.
public struct ResolvedOffer: Sendable, Equatable {
    public let clipboardId: UInt32
    public let formats: [ResolvedFormat]
    public init(clipboardId: UInt32, formats: [ResolvedFormat]) {
        self.clipboardId = clipboardId
        self.formats = formats
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
/// Not implemented in v1: `FEATURE_DRAG_V1` (we never advertise it, and
/// reject `DragItem` stream opens), and file representations — one with
/// `file_name` set is skipped, since NSPasteboard file promises are a
/// separate mechanism from the content forms we sync.
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

    /// Ceiling on a single inbound representation. The streaming layer
    /// has no length prefix we can trust before the fact, so this caps
    /// what a misbehaving peer can make us buffer.
    public static let maxInboundRepresentationBytes: Int = 64 * 1024 * 1024

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

    /// The most recently sent offer — the only one we serve stream
    /// opens against, since a new offer supersedes its predecessor.
    private var lastOutboundOffer: OutboundOffer?
    /// The in-progress inbound offer. Also single-slot: a new inbound
    /// offer supersedes the prior one.
    private var pendingInbound: PartialInboundOffer?
    /// Streams we opened and are still receiving, keyed by stream id.
    private var inboundStreams: [UInt32: InboundStream] = [:]
    /// Streams the peer opened on us that we're still feeding.
    private var outboundStreamsInFlight: Set<UInt32> = []
    /// Subset of the above the peer has asked us to abort.
    private var cancelledOutboundStreams: Set<UInt32> = []

    private struct OutboundOffer {
        let clipboardId: UInt32
        let token: ClipboardSnapshotToken
        /// Representation metadata by `index`, for serving stream opens.
        let representations: [UInt32: OutboundRepresentation]
    }

    private struct OutboundRepresentation {
        let mime: String
        let compression: Compression
    }

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
                slot.data.map { ResolvedFormat(mime: slot.mime, data: $0) }
            }
        }
    }

    private struct InboundStream {
        let clipboardId: UInt32
        let index: UInt32
        let compression: Compression
        let expectedSize: UInt64
        var buffer: Data
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
        let counts = "pendingInbound=\(pendingInbound != nil) inboundStreams=\(inboundStreams.count) outboundInFlight=\(outboundStreamsInFlight.count) lastOutbound=\(lastOutboundOffer != nil)"
        log.info("[BRIDGE] reset (\(reason, privacy: .public)): \(counts, privacy: .public)")
        pendingInbound = nil
        inboundStreams.removeAll()
        lastOutboundOffer = nil
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
            // We never advertise FEATURE_DRAG_V1, so a conforming peer
            // won't send these.
            log.debug("[BRIDGE] inbound: drag offer id=\(d.dragID, privacy: .public) ignored (drag unsupported)")

        case .dragEnd(let d):
            log.debug("[BRIDGE] inbound: drag end id=\(d.dragID, privacy: .public) ignored (drag unsupported)")
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
            guard Self.acceptedMimes.contains(canonicalMime(descriptor.mime)) else {
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
                    metadata[index] = OutboundRepresentation(mime: descriptor.mime, compression: actual)
                    nextIndex += 1
                    continue
                }
            }

            // Streamed: advertise only, keep the bytes in the source and
            // serve them when the peer opens a stream.
            log.debug("[BRIDGE] sendOffer[\(clipboardId, privacy: .public)]: idx=\(index, privacy: .public) '\(descriptor.mime, privacy: .public)' size=\(descriptor.size, privacy: .public) → stream (compression=\(compression.rawValue, privacy: .public))")
            representations.append(rep)
            metadata[index] = OutboundRepresentation(mime: descriptor.mime, compression: compression)
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

    private func handleStreamOpen(_ open: StreamOpen) async {
        let streamId = open.streamID

        guard case .clipboardItem(let item) = open.source else {
            // A DragItem, or a source variant added after this build.
            log.debug("[BRIDGE] stream_open \(streamId, privacy: .public): unsupported source; closing UNAVAILABLE")
            await sendStreamClose(streamId: streamId, status: .streamStatusUnavailable)
            return
        }
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

    private func handleStreamCancel(_ cancel: StreamCancel) async {
        let streamId = cancel.streamID
        guard outboundStreamsInFlight.contains(streamId) else {
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

        var partial = PartialInboundOffer(clipboardId: offer.clipboardID, slots: [])
        var opens: [(streamId: UInt32, index: UInt32)] = []

        for rep in offer.payload.representations {
            guard !rep.hasFileName else {
                log.debug("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): skip file representation '\(rep.fileName, privacy: .public)' (files unsupported in v1)")
                continue
            }
            guard Self.acceptedMimes.contains(canonicalMime(rep.mime)) else {
                log.debug("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): drop unaccepted MIME '\(rep.mime, privacy: .public)'")
                continue
            }

            if rep.hasInline {
                // `inline` present (even empty) ⇒ apply directly.
                if let decoded = decompress(rep.inline, using: rep.compression) {
                    partial.slots.append(.init(index: rep.index, mime: rep.mime, data: decoded, isPending: false))
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
                buffer: Data()
            )
            partial.slots.append(.init(index: rep.index, mime: rep.mime, data: nil, isPending: true))
            opens.append((streamId, rep.index))
        }

        if partial.slots.isEmpty {
            log.debug("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): nothing acceptable; ignoring")
            pendingInbound = nil
            return
        }

        pendingInbound = partial

        for open in opens {
            log.debug("[BRIDGE] inbound offer \(offer.clipboardID, privacy: .public): opening stream \(open.streamId, privacy: .public) for idx=\(open.index, privacy: .public)")
            await sendStreamOpen(
                streamId: open.streamId,
                clipboardId: offer.clipboardID,
                index: open.index
            )
        }

        // All-inline offers settle immediately.
        settleIfComplete()
    }

    private func handleStreamData(_ frame: StreamData) {
        guard var stream = inboundStreams[frame.streamID] else {
            log.debug("[BRIDGE] stream_data \(frame.streamID, privacy: .public): unknown/stale stream; dropping \(frame.data.count, privacy: .public)B")
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
        log.debug("[BRIDGE] inbound offer \(partial.clipboardId, privacy: .public): settled with \(formats.count, privacy: .public)/\(partial.slots.count, privacy: .public) representation(s); yielding")
        inboundOffersContinuation.yield(
            ResolvedOffer(clipboardId: partial.clipboardId, formats: formats)
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
                features: [.clipboardV1]
            )
            log.debug("[BRIDGE] outbound: hello ua='\(Self.userAgent, privacy: .public)' compressions=[none, deflate] features=[clipboardV1] wire=\(frame.count, privacy: .public)")
            _ = await sendFrame(frame)
        } catch {
            log.error("[BRIDGE] sendHello: encode failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func sendStreamOpen(streamId: UInt32, clipboardId: UInt32, index: UInt32) async {
        do {
            let frame = try ClipboardCodec.encodeClipboardStreamOpen(
                streamId: streamId,
                clipboardId: clipboardId,
                index: index
            )
            _ = await sendFrame(frame)
        } catch {
            log.error("[BRIDGE] sendStreamOpen: encode failed: \(String(describing: error), privacy: .public)")
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
