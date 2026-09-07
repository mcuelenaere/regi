import XCTest
import JetKVMKit
@testable import JetKVMKit

/// Bridge state-machine tests against a fake `ClipboardSource` and a
/// captured outbound-frame closure. No real WebRTC peer needed.
@MainActor
final class ClipboardBridgeTests: XCTestCase {

    // MARK: - Test doubles

    /// Records every frame the bridge tries to send.
    final class CapturingSink {
        var frames: [Data] = []
        func send(_ data: Data) async -> Bool {
            frames.append(data)
            return true
        }

        /// Decoded view of everything captured so far.
        func messages() throws -> [AgentMessage] {
            try frames.map { try ClipboardCodec.decode($0) }
        }
    }

    /// In-memory ClipboardSource the tests can mutate between bridge
    /// calls to simulate the local clipboard moving on. Ordered, so
    /// representation indices are deterministic.
    final class FakeSource: ClipboardSource, @unchecked Sendable {
        var currentToken: Int = 1
        var contents: [(mime: String, data: Data)] = []

        func snapshot() async -> ClipboardSnapshot {
            ClipboardSnapshot(
                token: ClipboardSnapshotToken(currentToken),
                formats: contents.map {
                    ClipboardFormatDescriptor(mime: $0.mime, size: UInt64($0.data.count))
                }
            )
        }

        func fetchData(mime: String, token: ClipboardSnapshotToken) async -> Data? {
            guard token.value == currentToken else { return nil }
            return contents.first { $0.mime == mime }?.data
        }

        /// Simulates the user copying something new.
        func bump(replacement: [(mime: String, data: Data)]) {
            currentToken += 1
            contents = replacement
        }
    }

    /// Deterministic pseudo-random bytes (xorshift32). Deflate can't
    /// shrink these, so tests that want to exercise the inline *budget*
    /// aren't defeated by the compressor.
    static func incompressibleBytes(_ count: Int, seed: UInt32) -> Data {
        var state = seed &* 2_654_435_761 | 1
        var out = Data(capacity: count)
        for _ in 0..<count {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            out.append(UInt8(truncatingIfNeeded: state))
        }
        return out
    }

    private func makeBridge(sink: CapturingSink) -> ClipboardBridge {
        ClipboardBridge { [weak sink] data in
            await sink?.send(data) ?? false
        }
    }

    private func makeHello(compressions: [Compression] = [.none, .deflate]) -> Data {
        try! ClipboardCodec.encodeHello(
            userAgent: "tinypipe/test",
            compressions: compressions,
            features: [.clipboardV1]
        )
    }

    /// Build an inbound offer message.
    private func makeOffer(
        clipboardId: UInt32,
        _ reps: [Representation]
    ) throws -> Data {
        var payload = Payload()
        payload.representations = reps
        var offer = ClipboardOffer()
        offer.clipboardID = clipboardId
        offer.payload = payload
        return try ClipboardCodec.encodeClipboardOffer(offer)
    }

    private func inlineRep(
        index: UInt32,
        mime: String,
        body: Data,
        uncompressedSize: UInt64? = nil,
        compression: Compression = .none
    ) -> Representation {
        var rep = Representation()
        rep.index = index
        rep.mime = mime
        rep.size = uncompressedSize ?? UInt64(body.count)
        rep.compression = compression
        rep.inline = body
        return rep
    }

    private func streamedRep(
        index: UInt32,
        mime: String,
        size: UInt64,
        compression: Compression = .none
    ) -> Representation {
        var rep = Representation()
        rep.index = index
        rep.mime = mime
        rep.size = size
        rep.compression = compression
        return rep
    }

    /// Start collecting the first resolved offer before feeding frames —
    /// `AsyncStream` is single-iteration, so the consumer has to exist up
    /// front.
    private func firstResolvedOffer(_ bridge: ClipboardBridge) -> Task<ResolvedOffer, Never> {
        Task { [bridge] in
            for await resolved in await bridge.inboundOffers { return resolved }
            return ResolvedOffer(clipboardId: 0, formats: [])
        }
    }

    // MARK: - Channel readiness + engagement

    func testChannelReadyWithoutEngagementIsSilent() async {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        await bridge.handleChannelReadyChange(true)
        // The handshake is client-initiated: nothing flies until engage().
        XCTAssertEqual(sink.frames.count, 0)
    }

    func testEngageBeforeChannelReadyDefersHello() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        await bridge.engage()
        XCTAssertEqual(sink.frames.count, 0)
        await bridge.handleChannelReadyChange(true)
        XCTAssertEqual(sink.frames.count, 1)
        guard case .hello = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected hello")
        }
    }

    func testEngageWhileChannelReadySendsHelloImmediately() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        await bridge.handleChannelReadyChange(true)
        XCTAssertEqual(sink.frames.count, 0)
        await bridge.engage()
        XCTAssertEqual(sink.frames.count, 1)
        guard case .hello(let h) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected hello")
        }
        XCTAssertEqual(h.supportedCompressions, [.none, .deflate])
        XCTAssertEqual(h.supportedFeatures, [.clipboardV1])
        XCTAssertFalse(h.userAgent.isEmpty)
        // We don't implement drag, so we must not advertise it.
        XCTAssertFalse(h.supportedFeatures.contains(.dragV1))
    }

    func testEngageIsIdempotent() async {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        await bridge.handleChannelReadyChange(true)
        await bridge.engage()
        await bridge.engage()
        await bridge.engage()
        XCTAssertEqual(sink.frames.count, 1)
    }

    func testChannelCycleReEngagedReHellos() async {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        await bridge.engage()
        await bridge.handleChannelReadyChange(true)
        XCTAssertEqual(sink.frames.count, 1)
        await bridge.handleChannelReadyChange(false)
        await bridge.handleChannelReadyChange(true)
        XCTAssertEqual(sink.frames.count, 2)
    }

    func testDisengageStopsReHelloingOnChannelCycle() async {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        await bridge.engage()
        await bridge.handleChannelReadyChange(true)
        bridge.disengage()
        await bridge.handleChannelReadyChange(false)
        await bridge.handleChannelReadyChange(true)
        XCTAssertEqual(sink.frames.count, 1)
    }

    /// Spec: receiving a Hello resets all per-connection state. A stream
    /// opened before it must be abandoned, not resolved by late frames.
    func testInboundHelloResetsInFlightStreams() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 1, [streamedRep(index: 0, mime: "image/png", size: 4)])
        )
        guard case .streamOpen(let open) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected stream_open")
        }
        sink.frames.removeAll()

        // Fresh peer.
        await bridge.handleInboundFrame(makeHello())

        // Late frames for the abandoned stream are ignored.
        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeStreamData(streamId: open.streamID, data: Data([1, 2, 3, 4]))
        )
        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeStreamClose(streamId: open.streamID, status: .streamStatusComplete)
        )
        XCTAssertEqual(sink.frames.count, 0, "no traffic for a reset stream")
    }

    // MARK: - Inbound: inline

    func testInboundInlineOfferYields() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 1, [
                inlineRep(index: 0, mime: "text/plain", body: Data("hello".utf8))
            ])
        )

        let resolved = await task.value
        XCTAssertEqual(resolved.clipboardId, 1)
        XCTAssertEqual(resolved.formats, [ResolvedFormat(mime: "text/plain", data: Data("hello".utf8))])
    }

    func testInboundDeflatedInlineDecompressed() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let text = String(repeating: "abc ", count: 200)
        let raw = Data(text.utf8)
        let compressed = try RawDeflate.compress(raw)
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 7, [
                inlineRep(
                    index: 0,
                    mime: "text/plain;charset=utf-8",
                    body: compressed,
                    uncompressedSize: UInt64(raw.count),
                    compression: .deflate
                )
            ])
        )

        let resolved = await task.value
        XCTAssertEqual(resolved.formats.first?.data, raw)
    }

    func testInboundUnacceptedMimeIsDropped() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 9, [
                inlineRep(index: 0, mime: "application/x-vendor-thing", body: Data("nope".utf8)),
                inlineRep(index: 1, mime: "text/plain", body: Data("yes".utf8)),
            ])
        )

        let resolved = await task.value
        XCTAssertEqual(resolved.formats.map(\.mime), ["text/plain"])
    }

    /// A representation with `file_name` set is a file; v1 doesn't apply
    /// those to NSPasteboard, so it's skipped without opening a stream.
    func testInboundFileRepresentationSkipped() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let task = firstResolvedOffer(bridge)

        var file = streamedRep(index: 0, mime: "text/plain", size: 999)
        file.fileName = "note.txt"

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 4, [
                file,
                inlineRep(index: 1, mime: "text/plain", body: Data("content".utf8)),
            ])
        )

        let resolved = await task.value
        XCTAssertEqual(resolved.formats.map(\.mime), ["text/plain"])
        XCTAssertEqual(resolved.formats.first?.data, Data("content".utf8))
        // No stream should have been opened for the file.
        XCTAssertEqual(sink.frames.count, 0)
    }

    func testInboundUnsupportedVersionDoesNotCrash() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        var envelope = Envelope()
        envelope.version = 2
        envelope.message = .hello(Hello())
        await bridge.handleInboundFrame(try envelope.serializedBytes())
        XCTAssertEqual(sink.frames.count, 0)
    }

    // MARK: - Inbound: streaming

    func testInboundStreamedRepresentationPullsAndResolves() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 42, [
                inlineRep(index: 0, mime: "text/plain", body: Data("preview".utf8)),
                streamedRep(index: 1, mime: "image/png", size: UInt64(png.count)),
            ])
        )

        // Exactly one StreamOpen, for the non-inlined representation.
        XCTAssertEqual(sink.frames.count, 1)
        guard case .streamOpen(let open) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected stream_open")
        }
        guard case .clipboardItem(let item) = open.source else {
            return XCTFail("expected clipboardItem source")
        }
        XCTAssertEqual(item.clipboardID, 42)
        XCTAssertEqual(item.index, 1)

        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeStreamData(streamId: open.streamID, data: png)
        )
        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeStreamClose(streamId: open.streamID, status: .streamStatusComplete)
        )

        let resolved = await task.value
        XCTAssertEqual(resolved.clipboardId, 42)
        // Offer order is preserved regardless of resolution order.
        XCTAssertEqual(resolved.formats.map(\.mime), ["text/plain", "image/png"])
        XCTAssertEqual(resolved.formats[1].data, png)
    }

    func testInboundStreamReassemblesMultipleChunks() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let whole = Data((0..<200_000).map { UInt8($0 % 251) })
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 5, [
                streamedRep(index: 0, mime: "image/png", size: UInt64(whole.count))
            ])
        )
        guard case .streamOpen(let open) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected stream_open")
        }

        var offset = 0
        while offset < whole.count {
            let end = min(offset + ClipboardBridge.streamChunkBytes, whole.count)
            await bridge.handleInboundFrame(
                try ClipboardCodec.encodeStreamData(
                    streamId: open.streamID,
                    data: whole.subdata(in: offset..<end)
                )
            )
            offset = end
        }
        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeStreamClose(streamId: open.streamID, status: .streamStatusComplete)
        )

        let resolved = await task.value
        XCTAssertEqual(resolved.formats.first?.data, whole)
    }

    func testInboundStreamDeflatedIsInflated() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let text = Data(String(repeating: "streamed text ", count: 500).utf8)
        let compressed = try RawDeflate.compress(text)
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 6, [
                streamedRep(index: 0, mime: "text/plain", size: UInt64(text.count), compression: .deflate)
            ])
        )
        guard case .streamOpen(let open) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected stream_open")
        }
        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeStreamData(streamId: open.streamID, data: compressed)
        )
        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeStreamClose(streamId: open.streamID, status: .streamStatusComplete)
        )

        let resolved = await task.value
        XCTAssertEqual(resolved.formats.first?.data, text)
    }

    /// The receiver verifies the decompressed length against the
    /// representation's declared `size`.
    func testInboundStreamSizeMismatchDropsRepresentation() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 11, [
                inlineRep(index: 0, mime: "text/plain", body: Data("keep".utf8)),
                streamedRep(index: 1, mime: "image/png", size: 100),
            ])
        )
        guard case .streamOpen(let open) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected stream_open")
        }
        // Only 3 bytes, but the offer promised 100.
        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeStreamData(streamId: open.streamID, data: Data([1, 2, 3]))
        )
        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeStreamClose(streamId: open.streamID, status: .streamStatusComplete)
        )

        let resolved = await task.value
        XCTAssertEqual(resolved.formats.map(\.mime), ["text/plain"])
    }

    func testInboundStreamNonCompleteCloseDropsRepresentation() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 12, [
                inlineRep(index: 0, mime: "text/plain", body: Data("keep".utf8)),
                streamedRep(index: 1, mime: "image/png", size: 10),
            ])
        )
        guard case .streamOpen(let open) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected stream_open")
        }
        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeStreamClose(streamId: open.streamID, status: .streamStatusUnavailable)
        )

        let resolved = await task.value
        XCTAssertEqual(resolved.formats.map(\.mime), ["text/plain"])
    }

    /// A new offer supersedes the previous one: pending pulls are
    /// cancelled and the stale offer never yields.
    func testInboundOfferSupersedesPendingAndCancelsStreams() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 1, [
                streamedRep(index: 0, mime: "image/png", size: 4096)
            ])
        )
        guard case .streamOpen(let open) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected stream_open")
        }
        sink.frames.removeAll()

        // User copies something new on the host.
        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 2, [
                inlineRep(index: 0, mime: "text/plain", body: Data("newer".utf8))
            ])
        )

        // The stale stream is cancelled…
        let cancels = try sink.messages().compactMap { msg -> UInt32? in
            if case .streamCancel(let c) = msg { return c.streamID }
            return nil
        }
        XCTAssertEqual(cancels, [open.streamID])

        // …and the first offer we see resolved is the newer one.
        let resolved = await task.value
        XCTAssertEqual(resolved.clipboardId, 2)
        XCTAssertEqual(resolved.formats.first?.data, Data("newer".utf8))
    }

    // MARK: - Outbound offers

    func testSendOfferWithoutPeerHelloIsNoop() async {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        source.contents = [("text/plain", Data("hello".utf8))]
        bridge.source = source

        await bridge.sendOffer()
        XCTAssertEqual(sink.frames.count, 0)
    }

    /// Bring the bridge to "handshake done", with the sink cleared.
    private func handshake(_ bridge: ClipboardBridge, _ sink: CapturingSink) async {
        await bridge.engage()
        await bridge.handleChannelReadyChange(true)
        await bridge.handleInboundFrame(makeHello())
        sink.frames.removeAll()
    }

    func testSendOfferInlinesSmallText() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        source.contents = [("text/plain", Data("hello".utf8))]
        bridge.source = source
        await handshake(bridge, sink)

        await bridge.sendOffer()
        XCTAssertEqual(sink.frames.count, 1)
        guard case .clipboardOffer(let o) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected clipboard offer")
        }
        XCTAssertEqual(o.clipboardID, 1)
        XCTAssertEqual(o.payload.representations.count, 1)
        let rep = o.payload.representations[0]
        XCTAssertEqual(rep.index, 0)
        XCTAssertEqual(rep.mime, "text/plain")
        XCTAssertTrue(rep.hasInline)
        XCTAssertEqual(rep.compression, .none)  // below deflateMinSize
        XCTAssertEqual(rep.inline, Data("hello".utf8))
        XCTAssertEqual(rep.size, 5)
    }

    func testSendOfferDeflatesLargeTextWhenPeerSupportsIt() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        let payload = Data(String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 50).utf8)
        source.contents = [("text/plain", payload)]
        bridge.source = source
        await handshake(bridge, sink)

        await bridge.sendOffer()
        guard case .clipboardOffer(let o) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected clipboard offer")
        }
        let rep = o.payload.representations[0]
        XCTAssertEqual(rep.compression, .deflate)
        // `size` is the UNCOMPRESSED length.
        XCTAssertEqual(rep.size, UInt64(payload.count))
        XCTAssertEqual(try RawDeflate.decompress(rep.inline), payload)
    }

    func testSendOfferWithoutPeerDeflateStaysUncompressed() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        let payload = Data(String(repeating: "compressible ", count: 100).utf8)
        source.contents = [("text/plain", payload)]
        bridge.source = source

        await bridge.engage()
        await bridge.handleChannelReadyChange(true)
        await bridge.handleInboundFrame(makeHello(compressions: [.none]))
        sink.frames.removeAll()

        await bridge.sendOffer()
        guard case .clipboardOffer(let o) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected clipboard offer")
        }
        XCTAssertEqual(o.payload.representations[0].compression, .none)
        XCTAssertEqual(o.payload.representations[0].inline, payload)
    }

    /// Anything past the inline budget is advertised only — `inline`
    /// absent tells the peer to open a stream.
    func testSendOfferLargeRepresentationIsStreamed() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        let bigPng = Data(repeating: 0xAB, count: 100 * 1024)
        source.contents = [("image/png", bigPng)]
        bridge.source = source
        await handshake(bridge, sink)

        await bridge.sendOffer()
        guard case .clipboardOffer(let o) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected clipboard offer")
        }
        let rep = o.payload.representations[0]
        XCTAssertEqual(rep.mime, "image/png")
        XCTAssertFalse(rep.hasInline)
        XCTAssertEqual(rep.size, UInt64(bigPng.count))
        // And the offer frame itself stays under the relay's cap.
        XCTAssertLessThanOrEqual(sink.frames[0].count, ClipboardCodec.maxFrameBytes)
    }

    func testSendOfferKeepsOfferFrameUnderCapWithManyFormats() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        // Four ~30 KiB incompressible formats: the budget lets the first
        // couple inline and pushes the rest to streams.
        source.contents = [
            ("text/plain", Self.incompressibleBytes(30_000, seed: 1)),
            ("text/html", Self.incompressibleBytes(30_000, seed: 2)),
            ("image/png", Self.incompressibleBytes(30_000, seed: 3)),
            ("text/uri-list", Self.incompressibleBytes(30_000, seed: 4)),
        ]
        bridge.source = source
        await handshake(bridge, sink)

        await bridge.sendOffer()
        XCTAssertEqual(sink.frames.count, 1)
        XCTAssertLessThanOrEqual(sink.frames[0].count, ClipboardCodec.maxFrameBytes)
        guard case .clipboardOffer(let o) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected clipboard offer")
        }
        XCTAssertEqual(o.payload.representations.count, 4)
        XCTAssertTrue(
            o.payload.representations.contains { !$0.hasInline },
            "budget should have pushed at least one representation to a stream"
        )
        // Indices are dense and in order — they're the pull handles.
        XCTAssertEqual(o.payload.representations.map(\.index), [0, 1, 2, 3])
    }

    func testSendOfferSkipsUnacceptedMimes() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        source.contents = [
            ("application/x-thing", Data("nope".utf8)),
            ("text/plain", Data("yes".utf8)),
        ]
        bridge.source = source
        await handshake(bridge, sink)

        await bridge.sendOffer()
        guard case .clipboardOffer(let o) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected clipboard offer")
        }
        XCTAssertEqual(o.payload.representations.map(\.mime), ["text/plain"])
        XCTAssertEqual(o.payload.representations[0].index, 0)
    }

    func testClipboardIdIsMonotonic() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        source.contents = [("text/plain", Data("a".utf8))]
        bridge.source = source
        await handshake(bridge, sink)

        await bridge.sendOffer()
        source.bump(replacement: [("text/plain", Data("b".utf8))])
        await bridge.sendOffer()

        let ids = try sink.messages().compactMap { msg -> UInt32? in
            if case .clipboardOffer(let o) = msg { return o.clipboardID }
            return nil
        }
        XCTAssertEqual(ids, [1, 2])
    }

    // MARK: - Serving streams for our own offers

    /// Drive an outbound offer and return the clipboard id the bridge
    /// allocated for it.
    private func sendOfferAndClipboardId(
        _ bridge: ClipboardBridge,
        _ sink: CapturingSink
    ) async throws -> UInt32 {
        await bridge.sendOffer()
        guard case .clipboardOffer(let o) = try ClipboardCodec.decode(sink.frames[0]) else {
            throw XCTSkip("expected clipboard offer")
        }
        sink.frames.removeAll()
        return o.clipboardID
    }

    func testStreamOpenServesRepresentationAndCompletes() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        let bigPng = Data((0..<150_000).map { UInt8($0 % 251) })
        source.contents = [("image/png", bigPng)]
        bridge.source = source
        await handshake(bridge, sink)
        let clipboardId = try await sendOfferAndClipboardId(bridge, sink)

        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeClipboardStreamOpen(streamId: 77, clipboardId: clipboardId, index: 0)
        )

        var assembled = Data()
        var sawComplete = false
        for msg in try sink.messages() {
            switch msg {
            case .streamData(let d):
                XCTAssertEqual(d.streamID, 77)
                assembled.append(d.data)
            case .streamClose(let c):
                XCTAssertEqual(c.streamID, 77)
                XCTAssertEqual(c.status, .streamStatusComplete)
                sawComplete = true
            default:
                XCTFail("unexpected message while serving a stream: \(msg)")
            }
        }
        XCTAssertTrue(sawComplete, "stream must end with exactly one StreamClose")
        XCTAssertEqual(assembled, bigPng)
        // Every frame must respect the relay's cap.
        for frame in sink.frames {
            XCTAssertLessThanOrEqual(frame.count, ClipboardCodec.maxFrameBytes)
        }
    }

    func testStreamOpenForStaleClipboardIdIsUnavailable() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        source.contents = [("image/png", Data(repeating: 0x42, count: 100 * 1024))]
        bridge.source = source
        await handshake(bridge, sink)
        let clipboardId = try await sendOfferAndClipboardId(bridge, sink)

        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeClipboardStreamOpen(
                streamId: 5,
                clipboardId: clipboardId &- 1,  // superseded
                index: 0
            )
        )
        guard case .streamClose(let c) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected stream_close")
        }
        XCTAssertEqual(c.status, .streamStatusUnavailable)
    }

    func testStreamOpenAfterLocalClipboardMovedIsUnavailable() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        source.contents = [("image/png", Data(repeating: 0x42, count: 100 * 1024))]
        bridge.source = source
        await handshake(bridge, sink)
        let clipboardId = try await sendOfferAndClipboardId(bridge, sink)

        // The user copies something else before the peer pulls.
        source.bump(replacement: [("text/plain", Data("new".utf8))])

        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeClipboardStreamOpen(streamId: 6, clipboardId: clipboardId, index: 0)
        )
        guard case .streamClose(let c) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected stream_close")
        }
        XCTAssertEqual(c.status, .streamStatusUnavailable)
    }

    func testStreamOpenForUnknownIndexIsUnavailable() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        source.contents = [("text/plain", Data("x".utf8))]
        bridge.source = source
        await handshake(bridge, sink)
        let clipboardId = try await sendOfferAndClipboardId(bridge, sink)

        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeClipboardStreamOpen(streamId: 8, clipboardId: clipboardId, index: 99)
        )
        guard case .streamClose(let c) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected stream_close")
        }
        XCTAssertEqual(c.status, .streamStatusUnavailable)
    }

    /// We never advertise FEATURE_DRAG_V1, so a drag pull gets refused
    /// rather than mis-served from the clipboard.
    func testStreamOpenForDragItemIsUnavailable() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        await handshake(bridge, sink)

        var item = StreamOpen.DragItem()
        item.dragID = 1
        item.index = 0
        var open = StreamOpen()
        open.streamID = 3
        open.source = .dragItem(item)
        await bridge.handleInboundFrame(try ClipboardCodec.encode(.streamOpen(open)))

        guard case .streamClose(let c) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected stream_close")
        }
        XCTAssertEqual(c.streamID, 3)
        XCTAssertEqual(c.status, .streamStatusUnavailable)
    }

    func testStreamOpenWithoutSourceIsError() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        source.contents = [("text/plain", Data("x".utf8))]
        bridge.source = source
        await handshake(bridge, sink)
        let clipboardId = try await sendOfferAndClipboardId(bridge, sink)

        // App layer detaches the source (sync toggled off).
        bridge.source = nil

        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeClipboardStreamOpen(streamId: 9, clipboardId: clipboardId, index: 0)
        )
        guard case .streamClose(let c) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected stream_close")
        }
        XCTAssertEqual(c.status, .streamStatusError)
    }

    /// A cancel for a stream that already closed must not produce a
    /// second StreamClose — the spec allows exactly one per stream.
    func testStreamCancelAfterCompletionIsIgnored() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        source.contents = [("text/plain", Data("x".utf8))]
        bridge.source = source
        await handshake(bridge, sink)
        let clipboardId = try await sendOfferAndClipboardId(bridge, sink)

        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeClipboardStreamOpen(streamId: 12, clipboardId: clipboardId, index: 0)
        )
        let framesAfterServe = sink.frames.count

        await bridge.handleInboundFrame(try ClipboardCodec.encodeStreamCancel(streamId: 12))
        XCTAssertEqual(sink.frames.count, framesAfterServe, "no extra close for a finished stream")
    }
}
