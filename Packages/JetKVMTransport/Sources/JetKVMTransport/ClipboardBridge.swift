import Foundation
import JetKVMProtocol
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "clipboard")

/// Opaque handle identifying one point in the local clipboard's
/// history. Re-reads against the same token are guaranteed to return
/// the same bytes or fail (`nil`) — used to enforce the "offer expired"
/// semantics of `ClipboardResponseV1.STATUS_UNAVAILABLE`.
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
/// can advertise representations with `size_hint` and later re-read
/// them on demand, falling back to `STATUS_UNAVAILABLE` if the local
/// clipboard has changed in the meantime.
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
/// representation either inlined or fetched. Drives the "host clipboard
/// just changed; here's what's on it" UI flow.
public struct ResolvedOffer: Sendable, Equatable {
    public let offerId: UInt32
    public let formats: [ResolvedFormat]
    public init(offerId: UInt32, formats: [ResolvedFormat]) {
        self.offerId = offerId
        self.formats = formats
    }
}

/// Pipes the agent-protocol `Envelope` stream over the `host_bridge`
/// data channel into and out of a local clipboard source.
///
/// Wire-protocol concerns live here — Hello / Offer / Request /
/// Response framing, compression negotiation, MIME filtering. The App
/// layer plugs in its NSPasteboard-backed `ClipboardSource` and
/// subscribes to `inboundOffers` to apply incoming events.
@MainActor
public final class ClipboardBridge {
    /// Wire MIMEs the W3C Async Clipboard API accepts (modulo the
    /// "web "-prefixed custom space, which we don't surface in v1).
    /// Used for both outbound filtering (don't ship formats the host's
    /// agent can't normalize back into the host's clipboard) and
    /// inbound filtering (don't waste a fetch round-trip on
    /// representations we can't apply).
    public static let acceptedMimes: Set<String> = [
        "text/plain",
        "text/html",
        "image/png",
        "text/uri-list",
    ]

    /// Above this raw byte size, outbound formats are advertised by
    /// `size_hint` and bytes are fetched on demand. Matches the
    /// SHOULD-inline threshold the spec recommends.
    public static let inlineThreshold: Int = 64 * 1024

    /// Max bytes we'll ship in a single response data field. The
    /// relay's 8 MiB frame cap is the hard wall; we leave headroom for
    /// envelope overhead so we never produce a frame the relay would
    /// drop with `1009 Message Too Big`.
    public static let maxResponseDataSize: Int = (8 * 1024 * 1024) - 1024

    /// Compress text payloads at or above this raw size when peer
    /// advertised deflate. Smaller payloads don't compress meaningfully.
    public static let deflateMinSize: Int = 256

    /// Source for the local clipboard. App layer assigns this before
    /// the bridge can ship outbound offers. When nil, `sendOffer()` is
    /// a no-op (logs a debug line); inbound offers still resolve and
    /// reach `inboundOffers`.
    public var source: ClipboardSource?

    /// What the peer's `Hello` told us they can decode. `nil` until the
    /// peer's `Hello` is parsed; sender compression defaults to `.none`
    /// in that window.
    public private(set) var peerHello: Hello?

    /// Stream of fully-resolved inbound offers. One element per agent
    /// clipboard event, with all advertised representations either
    /// inlined or fetched.
    public let inboundOffers: AsyncStream<ResolvedOffer>

    // MARK: - Internal state

    private let sendFrame: @Sendable (Data) async -> Bool
    private let inboundOffersContinuation: AsyncStream<ResolvedOffer>.Continuation

    /// `true` when the App layer has called `engage()` — the user has
    /// opted into clipboard sync for this session. The bridge stays
    /// silent on the wire until engaged: no Hello, no offers. Cleared
    /// by `disengage()`. The agent's WS to JetKVM can cycle freely
    /// without producing Hello flood — only an engaged Regi initiates.
    private var isEngaged: Bool = false
    /// Mirror of the host_bridge data-channel ready state. Lets
    /// `engage()` ship Hello immediately if the channel happens to
    /// already be open, and lets `handleChannelReadyChange(true)`
    /// ship Hello if engagement happened first.
    private var channelReady: Bool = false

    private var nextOutboundOfferId: UInt32 = 1
    /// Single-slot: the most recently sent offer. Used to serve inbound
    /// `ClipboardRequestV1` against the App layer's source. Prior
    /// offers are implicitly invalidated per spec.
    private var lastOutboundOffer: (offerId: UInt32, token: ClipboardSnapshotToken)?
    /// Single-slot: the in-progress inbound offer. Per spec each new
    /// offer from the same peer invalidates the prior, so we only ever
    /// track one.
    private var pendingInbound: PartialInboundOffer?

    private struct PartialInboundOffer {
        let offerId: UInt32
        var resolved: [ResolvedFormat]
        var pending: Set<String>
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
    /// initiates the Hello dance — ships our `Envelope{hello}` to the
    /// agent now if the channel is open, and on every subsequent
    /// channel-ready transition until `disengage()` is called.
    ///
    /// Idempotent. Calling `engage()` while already engaged is a no-op.
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

    /// Opposite of `engage()`. Bridge stops initiating Hello on channel
    /// readiness. Already-exchanged peer state (peerHello) is retained
    /// so a quick toggle-off/on doesn't waste a round trip — only a
    /// channel close clears it.
    public func disengage() {
        log.info("[BRIDGE] disengage(): was isEngaged=\(self.isEngaged, privacy: .public)")
        isEngaged = false
    }

    // MARK: - Channel lifecycle

    /// Called by Session's pump when the `host_bridge` data channel's
    /// readyState changes. On `true` we (re-)initiate the Hello dance
    /// iff currently engaged; on `false` we clear all per-connection
    /// state so a reconnect starts fresh.
    public func handleChannelReadyChange(_ ready: Bool) async {
        let prevReady = channelReady
        channelReady = ready
        log.info("[BRIDGE] handleChannelReadyChange: \(prevReady, privacy: .public) → \(ready, privacy: .public); isEngaged=\(self.isEngaged, privacy: .public)")
        if ready && !prevReady && isEngaged {
            log.info("[BRIDGE] shipping Hello (channel just became ready while engaged)")
            // Fresh channel + we're engaged — re-do the Hello dance.
            await sendHello()
        }
        if !ready {
            let hadPeerHello = peerHello != nil
            let hadPendingInbound = pendingInbound != nil
            let hadLastOutbound = lastOutboundOffer != nil
            peerHello = nil
            pendingInbound = nil
            lastOutboundOffer = nil
            log.info("[BRIDGE] channel down — cleared peerHello=\(hadPeerHello, privacy: .public) pendingInbound=\(hadPendingInbound, privacy: .public) lastOutbound=\(hadLastOutbound, privacy: .public)")
            // Don't reset nextOutboundOfferId — fine to keep monotonic
            // across reconnects from our side; the peer treats each
            // fresh WS as its own offerId space anyway and we don't
            // share IDs with theirs.
        }
    }

    /// Called by Session's pump for each binary frame on `host_bridge`.
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
            peerHello = h
            log.info("[BRIDGE] inbound: hello protocolVersion=\(h.protocolVersion, privacy: .public) compressions=\(h.compressions.map(\.rawValue), privacy: .public) features=\(h.supportedFeatures.map(\.rawValue), privacy: .public)")

        case .offer(let o):
            log.debug("[BRIDGE] inbound: offer id=\(o.offerID, privacy: .public) formats=\(o.formats.count, privacy: .public)")
            await handleInboundOffer(o)

        case .request(let r):
            log.debug("[BRIDGE] inbound: request offer_id=\(r.offerID, privacy: .public) mime='\(r.mime, privacy: .public)'")
            await handleInboundRequest(r)

        case .response(let r):
            log.debug("[BRIDGE] inbound: response offer_id=\(r.offerID, privacy: .public) mime='\(r.mime, privacy: .public)' status=\(r.status.rawValue, privacy: .public) bytes=\(r.data.count, privacy: .public)")
            handleInboundResponse(r)
        }
    }

    // MARK: - Outbound

    /// Snapshot the local clipboard and ship an offer. No-op if the
    /// channel isn't ready (no peerHello yet) or no source is
    /// registered.
    public func sendOffer() async {
        log.debug("[BRIDGE] sendOffer: entering (source=\(self.source == nil ? "nil" : "set", privacy: .public) peerHello=\(self.peerHello == nil ? "nil" : "set", privacy: .public))")
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

        var offer = ClipboardOfferV1()
        let offerId = nextOutboundOfferId
        nextOutboundOfferId &+= 1
        offer.offerID = offerId

        for descriptor in snapshot.formats {
            guard Self.acceptedMimes.contains(canonicalMime(descriptor.mime)) else {
                log.debug("[BRIDGE] sendOffer[\(offerId, privacy: .public)]: drop unaccepted MIME '\(descriptor.mime, privacy: .public)'")
                continue
            }
            let format = await buildOfferFormat(
                descriptor: descriptor,
                token: snapshot.token,
                source: source,
                offerId: offerId
            )
            if let format {
                offer.formats.append(format)
            }
        }

        guard !offer.formats.isEmpty else {
            log.debug("[BRIDGE] sendOffer[\(offerId, privacy: .public)]: snapshot had no acceptable formats; not sending")
            return
        }

        do {
            let frame = try ClipboardCodec.encodeOffer(offer)
            log.debug("[BRIDGE] outbound: offer id=\(offerId, privacy: .public) formats=\(offer.formats.count, privacy: .public) wire_bytes=\(frame.count, privacy: .public)")
            guard await sendFrame(frame) else {
                log.error("[BRIDGE] sendOffer[\(offerId, privacy: .public)]: sendFrame returned false; channel may be closed")
                return
            }
            lastOutboundOffer = (offerId, snapshot.token)
            log.debug("[BRIDGE] sendOffer[\(offerId, privacy: .public)]: stored lastOutboundOffer with token=\(snapshot.token.value, privacy: .public)")
        } catch {
            log.error("[BRIDGE] sendOffer[\(offerId, privacy: .public)]: encode failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Build one `ClipboardOfferV1.Format`. Inlines if the format fits;
    /// otherwise advertises `size_hint` and leaves the bytes in the
    /// source for on-request fetch.
    private func buildOfferFormat(
        descriptor: ClipboardFormatDescriptor,
        token: ClipboardSnapshotToken,
        source: ClipboardSource,
        offerId: UInt32
    ) async -> ClipboardOfferV1.Format? {
        var format = ClipboardOfferV1.Format()
        format.mime = descriptor.mime

        if descriptor.size > UInt64(Self.inlineThreshold) {
            // Large: advertise size_hint, fetch on request.
            format.sizeHint = descriptor.size
            log.debug("[BRIDGE] sendOffer[\(offerId, privacy: .public)]: '\(descriptor.mime, privacy: .public)' size=\(descriptor.size, privacy: .public) > inlineThreshold → size_hint")
            return format
        }

        // Small: read + inline.
        guard let raw = await source.fetchData(mime: descriptor.mime, token: token) else {
            log.debug("[BRIDGE] sendOffer[\(offerId, privacy: .public)]: source raced on '\(descriptor.mime, privacy: .public)' at token=\(token.value, privacy: .public); dropping")
            return nil
        }
        var inline = ClipboardOfferV1.InlineData()
        let (payload, compression) = compressForInline(
            mime: descriptor.mime,
            raw: raw
        )
        inline.compression = compression
        inline.data = payload
        format.inline = inline
        log.debug("[BRIDGE] sendOffer[\(offerId, privacy: .public)]: '\(descriptor.mime, privacy: .public)' inline raw=\(raw.count, privacy: .public) payload=\(payload.count, privacy: .public) compression=\(compression.rawValue, privacy: .public)")
        return format
    }

    /// Pick a compression for an outbound inline payload. Deflate text
    /// when the peer supports it AND the result is actually smaller;
    /// pass binary (image/png) through uncompressed.
    private func compressForInline(mime: String, raw: Data) -> (Data, Compression) {
        guard peerSupportsDeflate, isTextMime(mime), raw.count >= Self.deflateMinSize else {
            return (raw, .none)
        }
        do {
            let deflated = try RawDeflate.compress(raw)
            if deflated.count < raw.count {
                return (deflated, .deflate)
            }
            return (raw, .none)
        } catch {
            log.error("compressForInline: deflate failed, falling back to none: \(String(describing: error), privacy: .public)")
            return (raw, .none)
        }
    }

    private var peerSupportsDeflate: Bool {
        peerHello?.compressions.contains(.deflate) ?? false
    }

    private func isTextMime(_ mime: String) -> Bool {
        let canon = canonicalMime(mime)
        return canon == "text/plain" || canon == "text/html" || canon == "text/uri-list"
    }

    /// Normalize a wire MIME to its set-membership form. `text/plain`
    /// and `text/plain;charset=utf-8` both collapse to `text/plain` so
    /// the accepted-MIMEs set membership check is simple.
    private func canonicalMime(_ mime: String) -> String {
        let lower = mime.lowercased()
        if let semicolon = lower.firstIndex(of: ";") {
            return String(lower[..<semicolon]).trimmingCharacters(in: .whitespaces)
        }
        return lower
    }

    // MARK: - Inbound dispatch

    private func handleInboundOffer(_ offer: ClipboardOfferV1) async {
        // Per spec: a new offer from the same peer invalidates prior.
        if let prior = pendingInbound {
            log.debug("[BRIDGE] inbound offer \(offer.offerID, privacy: .public) supersedes pending \(prior.offerId, privacy: .public)")
        }
        var partial = PartialInboundOffer(
            offerId: offer.offerID,
            resolved: [],
            pending: []
        )

        for format in offer.formats {
            let canon = canonicalMime(format.mime)
            guard Self.acceptedMimes.contains(canon) else {
                log.debug("[BRIDGE] inbound offer \(offer.offerID, privacy: .public): drop unaccepted MIME '\(format.mime, privacy: .public)'")
                continue
            }
            switch format.body {
            case .inline(let inline):
                if let decoded = decompress(data: inline.data, compression: inline.compression) {
                    partial.resolved.append(ResolvedFormat(mime: format.mime, data: decoded))
                    log.debug("[BRIDGE] inbound offer \(offer.offerID, privacy: .public): inline '\(format.mime, privacy: .public)' compression=\(inline.compression.rawValue, privacy: .public) wire=\(inline.data.count, privacy: .public) decoded=\(decoded.count, privacy: .public)")
                } else {
                    log.error("[BRIDGE] inbound offer \(offer.offerID, privacy: .public): failed to decompress inline '\(format.mime, privacy: .public)'")
                }
            case .sizeHint(let n):
                partial.pending.insert(format.mime)
                log.debug("[BRIDGE] inbound offer \(offer.offerID, privacy: .public): size_hint=\(n, privacy: .public) for '\(format.mime, privacy: .public)' — issuing request")
                await sendRequest(offerId: offer.offerID, mime: format.mime)
            case .none:
                log.error("[BRIDGE] inbound offer \(offer.offerID, privacy: .public) format '\(format.mime, privacy: .public)' has no body; dropping")
            }
        }

        if partial.pending.isEmpty {
            log.debug("[BRIDGE] inbound offer \(offer.offerID, privacy: .public): all formats inline (resolved=\(partial.resolved.count, privacy: .public)); yielding")
            yield(partial)
        } else {
            log.debug("[BRIDGE] inbound offer \(offer.offerID, privacy: .public): pending fetches for \(partial.pending.count, privacy: .public) format(s); buffering")
            pendingInbound = partial
        }
    }

    private func handleInboundResponse(_ response: ClipboardResponseV1) {
        guard var partial = pendingInbound,
              partial.offerId == response.offerID else {
            log.debug("[BRIDGE] inbound response: no pending offer matching id=\(response.offerID, privacy: .public); dropping")
            return
        }
        guard partial.pending.remove(response.mime) != nil else {
            log.debug("[BRIDGE] inbound response: not awaiting mime '\(response.mime, privacy: .public)' for offer \(response.offerID, privacy: .public); dropping")
            return
        }

        switch response.status {
        case .ok:
            if let data = decompress(data: response.data, compression: response.compression) {
                partial.resolved.append(ResolvedFormat(mime: response.mime, data: data))
                log.debug("[BRIDGE] inbound response: offer=\(response.offerID, privacy: .public) '\(response.mime, privacy: .public)' OK compression=\(response.compression.rawValue, privacy: .public) wire=\(response.data.count, privacy: .public) decoded=\(data.count, privacy: .public)")
            } else {
                log.error("[BRIDGE] inbound response OK but decompression failed for '\(response.mime, privacy: .public)'")
            }
        case .unavailable, .tooLarge, .error, .unspecified:
            log.debug("[BRIDGE] inbound response status=\(response.status.rawValue, privacy: .public) for '\(response.mime, privacy: .public)'; dropping representation")
        case .UNRECOGNIZED(let n):
            log.error("[BRIDGE] inbound response unknown status=\(n, privacy: .public); dropping representation")
        }

        if partial.pending.isEmpty {
            log.debug("[BRIDGE] inbound response: offer=\(response.offerID, privacy: .public) — all fetches done (resolved=\(partial.resolved.count, privacy: .public)); yielding")
            pendingInbound = nil
            yield(partial)
        } else {
            log.debug("[BRIDGE] inbound response: offer=\(response.offerID, privacy: .public) — still pending \(partial.pending.count, privacy: .public) fetch(es)")
            pendingInbound = partial
        }
    }

    private func handleInboundRequest(_ request: ClipboardRequestV1) async {
        // Validate against our last outbound offer.
        guard let last = lastOutboundOffer, last.offerId == request.offerID else {
            let known = lastOutboundOffer?.offerId.description ?? "nil"
            log.debug("[BRIDGE] inbound request: offer_id=\(request.offerID, privacy: .public) doesn't match our last outbound (=\(known, privacy: .public)); responding UNAVAILABLE")
            await respondUnavailable(offerId: request.offerID, mime: request.mime)
            return
        }
        guard let source else {
            log.error("[BRIDGE] inbound request offer=\(request.offerID, privacy: .public): no clipboard source registered; responding ERROR")
            await respondError(offerId: request.offerID, mime: request.mime)
            return
        }
        guard let data = await source.fetchData(mime: request.mime, token: last.token) else {
            log.debug("[BRIDGE] inbound request offer=\(request.offerID, privacy: .public): source raced (token=\(last.token.value, privacy: .public)); responding UNAVAILABLE")
            await respondUnavailable(offerId: request.offerID, mime: request.mime)
            return
        }

        // Decide compression + cap on response size.
        let (payload, compression) = compressForInline(mime: request.mime, raw: data)
        if payload.count > Self.maxResponseDataSize {
            log.debug("[BRIDGE] inbound request offer=\(request.offerID, privacy: .public): '\(request.mime, privacy: .public)' \(payload.count, privacy: .public) bytes exceeds frame cap; responding TOO_LARGE")
            await respondTooLarge(offerId: request.offerID, mime: request.mime)
            return
        }

        var response = ClipboardResponseV1()
        response.offerID = request.offerID
        response.mime = request.mime
        response.status = .ok
        response.compression = compression
        response.data = payload
        log.debug("[BRIDGE] inbound request offer=\(request.offerID, privacy: .public): serving '\(request.mime, privacy: .public)' raw=\(data.count, privacy: .public) payload=\(payload.count, privacy: .public) compression=\(compression.rawValue, privacy: .public)")
        await encodeAndSendResponse(response)
    }

    // MARK: - Response helpers

    private func respondUnavailable(offerId: UInt32, mime: String) async {
        var r = ClipboardResponseV1()
        r.offerID = offerId
        r.mime = mime
        r.status = .unavailable
        await encodeAndSendResponse(r)
    }

    private func respondTooLarge(offerId: UInt32, mime: String) async {
        var r = ClipboardResponseV1()
        r.offerID = offerId
        r.mime = mime
        r.status = .tooLarge
        await encodeAndSendResponse(r)
    }

    private func respondError(offerId: UInt32, mime: String) async {
        var r = ClipboardResponseV1()
        r.offerID = offerId
        r.mime = mime
        r.status = .error
        await encodeAndSendResponse(r)
    }

    private func encodeAndSendResponse(_ r: ClipboardResponseV1) async {
        do {
            let frame = try ClipboardCodec.encodeResponse(r)
            log.debug("[BRIDGE] outbound: response offer_id=\(r.offerID, privacy: .public) mime='\(r.mime, privacy: .public)' status=\(r.status.rawValue, privacy: .public) data=\(r.data.count, privacy: .public) wire=\(frame.count, privacy: .public)")
            _ = await sendFrame(frame)
        } catch {
            log.error("[BRIDGE] encodeAndSendResponse: encode failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func sendRequest(offerId: UInt32, mime: String) async {
        do {
            let frame = try ClipboardCodec.encodeRequest(offerId: offerId, mime: mime)
            log.debug("[BRIDGE] outbound: request offer_id=\(offerId, privacy: .public) mime='\(mime, privacy: .public)' wire=\(frame.count, privacy: .public)")
            _ = await sendFrame(frame)
        } catch {
            log.error("[BRIDGE] sendRequest: encode failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func sendHello() async {
        do {
            let frame = try ClipboardCodec.encodeHello(
                compressions: [.none, .deflate],
                features: [.clipboardWriteV1]
            )
            log.debug("[BRIDGE] outbound: hello compressions=[none, deflate] features=[clipboardWriteV1] wire=\(frame.count, privacy: .public)")
            _ = await sendFrame(frame)
        } catch {
            log.error("[BRIDGE] sendHello: encode failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Decompression

    private func decompress(data: Data, compression: Compression) -> Data? {
        switch compression {
        case .none, .unspecified:
            return data
        case .deflate:
            do {
                return try RawDeflate.decompress(data)
            } catch {
                log.error("decompress: inflate failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        case .UNRECOGNIZED(let n):
            log.error("decompress: unknown compression value \(n, privacy: .public); dropping")
            return nil
        }
    }

    // MARK: - Yield helper

    private func yield(_ partial: PartialInboundOffer) {
        let resolved = ResolvedOffer(offerId: partial.offerId, formats: partial.resolved)
        inboundOffersContinuation.yield(resolved)
    }
}
