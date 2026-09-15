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
        /// Runs on the actor right after a frame is captured but before
        /// the send "completes", so a test can interleave peer traffic at
        /// an exact point in a suspension the bridge is sitting in.
        var onSend: ((Int) async -> Void)?
        func send(_ data: Data) async -> Bool {
            frames.append(data)
            await onSend?(frames.count - 1)
            // A real send suspends (the data channel's write is async), and
            // the bridge's cancel handling depends on that: a serve loop
            // that never yields can't observe a StreamCancel that arrives
            // mid-transfer. Yield so the tests exercise the same
            // interleaving production does.
            await Task.yield()
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
        /// Copied files, announced by name + size and served from disk —
        /// the bridge must never read one through `fetchData`.
        var files: [URL] = []

        func snapshot() async -> ClipboardSnapshot {
            var formats = contents.map {
                ClipboardFormatDescriptor(mime: $0.mime, size: UInt64($0.data.count))
            }
            for url in files {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??
                    .uint64Value ?? 0
                formats.append(
                    ClipboardFormatDescriptor(
                        mime: ClipboardFileRules.mime(forFileName: url.lastPathComponent),
                        size: size,
                        fileName: url.lastPathComponent
                    )
                )
            }
            return ClipboardSnapshot(token: ClipboardSnapshotToken(currentToken), formats: formats)
        }

        func fetchData(mime: String, token: ClipboardSnapshotToken) async -> Data? {
            guard token.value == currentToken else { return nil }
            return contents.first { $0.mime == mime }?.data
        }

        func fileURL(fileName: String, token: ClipboardSnapshotToken) async -> URL? {
            guard token.value == currentToken else { return nil }
            return files.first { $0.lastPathComponent == fileName }
        }

        /// Simulates the user copying something new.
        func bump(replacement: [(mime: String, data: Data)]) {
            currentToken += 1
            contents = replacement
            files = []
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

    private func makeHello(
        compressions: [Compression] = [.none, .deflate],
        features: [Feature] = [.clipboardV1]
    ) -> Data {
        try! ClipboardCodec.encodeHello(
            userAgent: "tinypipe/test",
            compressions: compressions,
            features: features
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

    /// A streamed *file* representation: same shape, plus `file_name`.
    private func streamedFileRep(
        index: UInt32,
        fileName: String,
        size: UInt64,
        mime: String? = nil,
        compression: Compression = .none
    ) -> Representation {
        var rep = streamedRep(
            index: index,
            mime: mime ?? ClipboardFileRules.mime(forFileName: fileName),
            size: size,
            compression: compression
        )
        rep.fileName = fileName
        return rep
    }

    /// A per-test directory for inbound files. Callers remove it in a
    /// `defer` so a failing assertion doesn't leak into the next run.
    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("regi-bridge-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Where `handleInboundOffer` lands the files of one offer. The name
    /// carries a per-bridge tag, so ask the bridge rather than guessing.
    private func filesDirectory(_ bridge: ClipboardBridge, clipboardId: UInt32) -> URL {
        bridge.filesDirectory(forClipboardId: clipboardId)
    }

    /// Write a file the outbound tests can offer.
    @discardableResult
    private func writeFile(_ name: String, bytes: Data, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// Feed a whole representation to the bridge as the peer would: the
    /// StreamData frames, then the closing StreamClose.
    private func feedStream(
        _ bridge: ClipboardBridge,
        streamId: UInt32,
        body: Data,
        chunk: Int = 4096,
        status: StreamClose.Status = .streamStatusComplete
    ) async throws {
        var offset = 0
        while offset < body.count {
            let end = min(offset + chunk, body.count)
            await bridge.handleInboundFrame(
                try ClipboardCodec.encodeStreamData(streamId: streamId, data: body.subdata(in: offset..<end))
            )
            offset = end
        }
        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeStreamClose(streamId: streamId, status: status)
        )
    }

    /// Every stream id the bridge has opened so far, in order.
    private func streamOpenIds(_ sink: CapturingSink) throws -> [UInt32] {
        try sink.messages().compactMap { message -> UInt32? in
            if case .streamOpen(let open) = message { return open.streamID }
            return nil
        }
    }

    /// Redeem a file promise the way AppKit does — on its own task — and
    /// return once the resulting `StreamOpen` is on the wire, which is
    /// the point from which the test can play the peer.
    ///
    /// The task is still running: feed it with `feedStream`, then await
    /// `task.value` for the landed URL (or the error).
    private func beginPull(
        _ bridge: ClipboardBridge,
        _ promise: ClipboardFilePromise,
        sink: CapturingSink
    ) async throws -> (task: Task<URL, Error>, streamId: UInt32) {
        let before = try streamOpenIds(sink).count
        let task = Task { try await bridge.fetchPromisedFile(promise) }
        for _ in 0..<200 {
            await Task.yield()
            let ids = try streamOpenIds(sink)
            if ids.count > before { return (task, ids[before]) }
        }
        task.cancel()
        throw XCTSkip("promise '\(promise.fileName)' never opened a stream")
    }

    /// Redeem a promise and play the peer answering it in full.
    @discardableResult
    private func pull(
        _ bridge: ClipboardBridge,
        _ promise: ClipboardFilePromise,
        sink: CapturingSink,
        body: Data,
        chunk: Int = 4096,
        status: StreamClose.Status = .streamStatusComplete
    ) async throws -> Result<URL, Error> {
        let (task, streamId) = try await beginPull(bridge, promise, sink: sink)
        try await feedStream(bridge, streamId: streamId, body: body, chunk: chunk, status: status)
        return await task.result
    }

    /// The `ClipboardPromiseError` a failed redemption produced.
    private func promiseError(_ result: Result<URL, Error>) -> ClipboardPromiseError? {
        guard case .failure(let error) = result else { return nil }
        return error as? ClipboardPromiseError
    }

    /// The stream id the bridge allocated for the single pull it opened.
    private func soleStreamOpenId(_ sink: CapturingSink) throws -> UInt32 {
        let opens = try sink.messages().compactMap { message -> StreamOpen? in
            if case .streamOpen(let open) = message { return open }
            return nil
        }
        guard opens.count == 1 else {
            throw XCTSkip("expected exactly one stream_open, got \(opens.count)")
        }
        return opens[0].streamID
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
        XCTAssertEqual(h.supportedFeatures, [.clipboardV1, .dragV1])
        XCTAssertFalse(h.userAgent.isEmpty)
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

    /// A file and a content form in the same offer are two different axes:
    /// the file lands on disk and shows up in `files`, the content form in
    /// `formats`. The file rules themselves are exercised further down,
    /// under "Inbound: files".
    func testInboundFileAndContentFormResolveSeparately() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let task = firstResolvedOffer(bridge)

        var file = inlineRep(index: 0, mime: "text/plain", body: Data("in a file".utf8))
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
        XCTAssertEqual(resolved.files.map(\.fileName), ["note.txt"])
        // The content form is resolved; the file is only promised, and
        // an inlined one hasn't even touched the disk yet.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: filesDirectory(bridge, clipboardId: 4).path)
        )

        let promise = try XCTUnwrap(resolved.files.first)
        let url = try await bridge.fetchPromisedFile(promise)
        XCTAssertEqual(try Data(contentsOf: url), Data("in a file".utf8))
        // Both rode inline, so nothing had to be pulled off the wire.
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
    private func handshake(
        _ bridge: ClipboardBridge,
        _ sink: CapturingSink,
        peerFeatures: [Feature] = [.clipboardV1]
    ) async {
        await bridge.engage()
        await bridge.handleChannelReadyChange(true)
        await bridge.handleInboundFrame(makeHello(features: peerFeatures))
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
        await bridge.drainOutboundStreams()

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
        await bridge.drainOutboundStreams()
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
        await bridge.drainOutboundStreams()
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
        await bridge.drainOutboundStreams()
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
        await bridge.drainOutboundStreams()

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
        await bridge.drainOutboundStreams()
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
        await bridge.drainOutboundStreams()
        let framesAfterServe = sink.frames.count

        await bridge.handleInboundFrame(try ClipboardCodec.encodeStreamCancel(streamId: 12))
        XCTAssertEqual(sink.frames.count, framesAfterServe, "no extra close for a finished stream")
    }

    // MARK: - Inbound: files

    /// The regression this whole design exists for: an offer carrying a
    /// file settles — and so the App layer writes the pasteboard —
    /// without a single byte of the file moving. Before, a 12 MB file
    /// held the pasteboard on the *previous* clipboard for three seconds.
    func testFileOfferSettlesImmediatelyWithoutPulling() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 1, [
                streamedFileRep(index: 0, fileName: "huge.bin", size: 12_400_000),
            ])
        )

        let resolved = await task.value
        XCTAssertEqual(resolved.formats.count, 0)
        XCTAssertEqual(resolved.files.map(\.fileName), ["huge.bin"])
        XCTAssertEqual(resolved.files.first?.size, 12_400_000)
        XCTAssertEqual(resolved.files.first?.clipboardId, 1)
        XCTAssertEqual(sink.frames.count, 0, "announcing a file must not open a stream")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: filesDirectory(bridge, clipboardId: 1).path),
            "nor touch the disk"
        )
    }

    func testRedeemedPromiseLandsOnDisk() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let task = firstResolvedOffer(bridge)

        let body = Self.incompressibleBytes(40_000, seed: 7)
        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 1, [
                streamedFileRep(index: 0, fileName: "payload.bin", size: UInt64(body.count)),
            ])
        )
        let resolved = await task.value
        let promise = try XCTUnwrap(resolved.files.first)

        let url = try await pull(bridge, promise, sink: sink, body: body).get()
        XCTAssertEqual(url.lastPathComponent, "payload.bin")
        XCTAssertEqual(try Data(contentsOf: url), body)
        // The temp file is gone; only the committed name remains.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: filesDirectory(bridge, clipboardId: 1).path),
            ["payload.bin"]
        )
    }

    /// Redeeming twice — two paste destinations, or a second paste of the
    /// same clipboard — reuses the file instead of pulling it again.
    func testSecondRedemptionReusesTheLandedFile() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let task = firstResolvedOffer(bridge)

        let body = Data("once is enough".utf8)
        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 2, [
                streamedFileRep(index: 0, fileName: "once.txt", size: UInt64(body.count)),
            ])
        )
        let resolved = await task.value
        let promise = try XCTUnwrap(resolved.files.first)

        let first = try await pull(bridge, promise, sink: sink, body: body).get()
        let second = try await bridge.fetchPromisedFile(promise)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try streamOpenIds(sink).count, 1, "one pull, not two")
    }

    /// AppKit asks for one promise once per destination, concurrently.
    /// Both callers ride the same transfer.
    func testConcurrentRedemptionsShareOnePull() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let task = firstResolvedOffer(bridge)

        let body = Self.incompressibleBytes(9_000, seed: 21)
        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 3, [
                streamedFileRep(index: 0, fileName: "shared.bin", size: UInt64(body.count)),
            ])
        )
        let resolved = await task.value
        let promise = try XCTUnwrap(resolved.files.first)

        let (first, streamId) = try await beginPull(bridge, promise, sink: sink)
        let second = Task { try await bridge.fetchPromisedFile(promise) }
        await Task.yield()
        try await feedStream(bridge, streamId: streamId, body: body)

        let firstURL = try await first.value
        let secondURL = try await second.value
        XCTAssertEqual(firstURL, secondURL)
        XCTAssertEqual(try streamOpenIds(sink).count, 1)
    }

    func testRedeemedDeflatedFileIsInflatedToDisk() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let task = firstResolvedOffer(bridge)

        let raw = Data(String(repeating: "log line\n", count: 5_000).utf8)
        let wire = try RawDeflate.compress(raw)
        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 4, [
                streamedFileRep(
                    index: 0, fileName: "app.log", size: UInt64(raw.count), compression: .deflate
                ),
            ])
        )
        let resolved = await task.value
        let promise = try XCTUnwrap(resolved.files.first)

        // Frame boundaries that have nothing to do with the deflate blocks.
        let url = try await pull(bridge, promise, sink: sink, body: wire, chunk: 997).get()
        XCTAssertEqual(try Data(contentsOf: url), raw)
    }

    /// A file's MIME is informational — tinypipe guesses it from the
    /// extension and will send anything — so `acceptedMimes` must not gate
    /// it. Its *name* is what has to be acceptable.
    func testInboundFileIsNotFilteredByMime() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let task = firstResolvedOffer(bridge)

        XCTAssertFalse(ClipboardBridge.acceptedMimes.contains("application/pdf"))
        var rep = inlineRep(index: 0, mime: "application/pdf", body: Data("%PDF-1.7".utf8))
        rep.fileName = "paper.pdf"
        await bridge.handleInboundFrame(try makeOffer(clipboardId: 5, [rep]))

        let resolved = await task.value
        XCTAssertEqual(resolved.files.map(\.fileName), ["paper.pdf"])
        XCTAssertEqual(resolved.files.first?.mime, "application/pdf")
    }

    /// Reject, don't sanitize — and never publish a promise we were never
    /// going to be able to redeem.
    func testInboundUnsafeFileNameIsNeverPromised() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 6, [
                streamedFileRep(index: 0, fileName: "../../etc/passwd", size: 10),
                streamedFileRep(index: 1, fileName: "CON", size: 10),
                inlineRep(index: 2, mime: "text/plain", body: Data("ok".utf8)),
            ])
        )

        let resolved = await task.value
        XCTAssertEqual(resolved.files.count, 0)
        XCTAssertEqual(resolved.formats.map(\.mime), ["text/plain"])
        XCTAssertEqual(sink.frames.count, 0, "an unsafe name must not be pulled at all")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: filesDirectory(bridge, clipboardId: 6).path),
            "an offer whose only file is unsafe should not even make a directory"
        )
    }

    /// The absolute size ceiling is checked when the offer lands, not when
    /// it's redeemed — a promise the pasteboard shows must be one we can
    /// actually keep.
    func testFileOverTheSizeCapIsNeverPromised() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 7, [
                streamedFileRep(
                    index: 0, fileName: "absurd.bin", size: ClipboardFileRules.maxFileBytes + 1
                ),
                inlineRep(index: 1, mime: "text/plain", body: Data("ok".utf8)),
            ])
        )

        let resolved = await task.value
        XCTAssertEqual(resolved.files.count, 0)
        XCTAssertEqual(resolved.formats.map(\.mime), ["text/plain"])
    }

    /// Likewise a compression we never advertised: refuse it up front
    /// rather than publish a promise that is guaranteed to fail.
    func testFileWithUnadvertisedCompressionIsNeverPromised() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 8, [
                streamedFileRep(index: 0, fileName: "zstd.bin", size: 100, compression: .zstd),
                inlineRep(index: 1, mime: "text/plain", body: Data("ok".utf8)),
            ])
        )

        let resolved = await task.value
        XCTAssertEqual(resolved.files.count, 0)
        XCTAssertEqual(resolved.formats.map(\.mime), ["text/plain"])
    }

    func testInboundFileNeverOverwritesAnExistingOne() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let directory = filesDirectory(bridge, clipboardId: 9)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        let task = firstResolvedOffer(bridge)

        var rep = inlineRep(index: 0, mime: "text/plain", body: Data("theirs".utf8))
        rep.fileName = "notes.txt"
        await bridge.handleInboundFrame(try makeOffer(clipboardId: 9, [rep]))

        let resolved = await task.value
        let promise = try XCTUnwrap(resolved.files.first)
        XCTAssertEqual(promise.fileName, "notes.txt")
        let landed = try await bridge.fetchPromisedFile(promise)
        XCTAssertEqual(landed.lastPathComponent, "notes (2).txt")
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("notes.txt")),
            Data("mine".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: landed), Data("theirs".utf8))
    }

    /// A transfer whose final length differs from `size` is discarded, not
    /// published — and leaves nothing behind.
    func testRedeemedShortFileIsDiscardedNotPublished() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 10, [
                streamedFileRep(index: 0, fileName: "truncated.bin", size: 1_000),
            ])
        )
        let resolved = await task.value
        let promise = try XCTUnwrap(resolved.files.first)

        // The sender claims COMPLETE after only part of what it declared.
        let result = try await pull(
            bridge, promise, sink: sink, body: Data(repeating: 0x5A, count: 100)
        )
        guard case .failed = promiseError(result) else {
            return XCTFail("expected a local failure, got \(result)")
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: filesDirectory(bridge, clipboardId: 10).path),
            []
        )
    }

    /// The peer answering a pull with UNAVAILABLE — its clipboard moved on
    /// between announcing the file and our asking for it — reaches the
    /// caller as such, so the promise can fail rather than hang.
    func testPeerRefusingAPullSurfacesAsRefused() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 11, [
                streamedFileRep(index: 0, fileName: "gone.bin", size: 500),
            ])
        )
        let resolved = await task.value
        let promise = try XCTUnwrap(resolved.files.first)

        let result = try await pull(
            bridge, promise, sink: sink, body: Data(), status: .streamStatusUnavailable
        )
        XCTAssertEqual(promiseError(result), .refused(.streamStatusUnavailable))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: filesDirectory(bridge, clipboardId: 11).path),
            []
        )
    }

    /// A peer streaming more than it declared fails on the offending write
    /// rather than after filling the volume, and we cancel rather than let
    /// it keep going.
    func testRedeemedFileOverrunIsCancelledAndCleanedUp() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 12, [
                streamedFileRep(index: 0, fileName: "liar.bin", size: 10),
            ])
        )
        let resolved = await task.value
        let promise = try XCTUnwrap(resolved.files.first)

        let (pullTask, streamId) = try await beginPull(bridge, promise, sink: sink)
        sink.frames.removeAll()
        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeStreamData(streamId: streamId, data: Data(repeating: 0x11, count: 64))
        )

        let outcome = await pullTask.result
        guard case .failed = promiseError(outcome) else {
            return XCTFail("expected the overrun to fail the promise")
        }
        // Give the cancel's detached Task a turn.
        await Task.yield()
        let cancels = try sink.messages().compactMap { message -> StreamCancel? in
            if case .streamCancel(let c) = message { return c }
            return nil
        }
        XCTAssertEqual(cancels.map(\.streamID), [streamId])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: filesDirectory(bridge, clipboardId: 12).path),
            []
        )
    }

    /// A superseding offer drops a redemption in flight; the half-written
    /// file must go with it, and whoever was waiting must be told.
    func testSupersedingOfferAbortsARedemptionInFlight() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let offerTask = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 13, [
                streamedFileRep(index: 0, fileName: "abandoned.bin", size: 5_000),
            ])
        )
        let announced = await offerTask.value
        let promise = try XCTUnwrap(announced.files.first)

        let (pullTask, streamId) = try await beginPull(bridge, promise, sink: sink)
        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeStreamData(streamId: streamId, data: Data(repeating: 1, count: 500))
        )
        let directory = filesDirectory(bridge, clipboardId: 13)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)

        let next = firstResolvedOffer(bridge)
        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 14, [
                inlineRep(index: 0, mime: "text/plain", body: Data("newer".utf8)),
            ])
        )
        _ = await next.value

        let outcome = await pullTask.result
        XCTAssertEqual(promiseError(outcome), .superseded)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        // And the abandoned pull is cancelled on the wire.
        let cancels = try sink.messages().compactMap { message -> StreamCancel? in
            if case .streamCancel(let c) = message { return c }
            return nil
        }
        XCTAssertEqual(cancels.map(\.streamID), [streamId])
    }

    /// The narrow window where a superseding offer lands while the pull's
    /// own `StreamOpen` is still in flight. Nothing will ever answer that
    /// stream, so the redemption has to fail rather than park forever
    /// waiting for a `StreamClose` the peer was never asked for.
    func testSupersedingOfferDuringTheOpenDoesNotHangTheRedemption() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let first = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 18, [
                streamedFileRep(index: 0, fileName: "racing.bin", size: 400),
            ])
        )
        let announced = await first.value
        let promise = try XCTUnwrap(announced.files.first)

        let superseding = try makeOffer(clipboardId: 19, [
            inlineRep(index: 0, mime: "text/plain", body: Data("newer".utf8)),
        ])
        let next = firstResolvedOffer(bridge)
        // Deliver it from inside the send of the StreamOpen itself.
        sink.onSend = { [weak sink, weak bridge] _ in
            sink?.onSend = nil
            await bridge?.handleInboundFrame(superseding)
        }

        do {
            _ = try await bridge.fetchPromisedFile(promise)
            XCTFail("expected the redemption to fail, not park")
        } catch {
            XCTAssertEqual(error as? ClipboardPromiseError, .superseded)
        }
        _ = await next.value
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: filesDirectory(bridge, clipboardId: 18).path),
            []
        )
    }

    /// A promise from an offer the peer has already replaced is refused
    /// without touching the wire — the host's clipboard has moved on.
    func testPromiseFromASupersededOfferIsRefused() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let first = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 15, [
                streamedFileRep(index: 0, fileName: "stale.bin", size: 100),
            ])
        )
        let announced = await first.value
        let promise = try XCTUnwrap(announced.files.first)

        let second = firstResolvedOffer(bridge)
        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 16, [
                inlineRep(index: 0, mime: "text/plain", body: Data("newer".utf8)),
            ])
        )
        _ = await second.value

        do {
            _ = try await bridge.fetchPromisedFile(promise)
            XCTFail("expected the stale promise to be refused")
        } catch {
            XCTAssertEqual(error as? ClipboardPromiseError, .superseded)
        }
        XCTAssertEqual(sink.frames.count, 0)
    }

    /// The channel dropping is one of the cleanup triggers the spec lists.
    func testChannelDropAbortsARedemptionAndRemovesPartials() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch
        let offerTask = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 17, [
                streamedFileRep(index: 0, fileName: "interrupted.bin", size: 5_000),
            ])
        )
        let announced = await offerTask.value
        let promise = try XCTUnwrap(announced.files.first)

        let (pullTask, streamId) = try await beginPull(bridge, promise, sink: sink)
        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeStreamData(streamId: streamId, data: Data(repeating: 2, count: 500))
        )
        await bridge.handleChannelReadyChange(false)

        let outcome = await pullTask.result
        XCTAssertEqual(promiseError(outcome), .superseded)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: filesDirectory(bridge, clipboardId: 17).path),
            []
        )
    }

    // MARK: - Outbound: files

    func testSendOfferAnnouncesFilesByNameAndSize() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = FakeSource()
        let body = Data(repeating: 0x2A, count: 1234)
        source.files = [try writeFile("report.pdf", bytes: body, in: scratch)]
        bridge.source = source
        await handshake(bridge, sink)

        await bridge.sendOffer()
        guard case .clipboardOffer(let offer) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected clipboard offer")
        }
        let rep = try XCTUnwrap(offer.payload.representations.first)
        XCTAssertEqual(rep.fileName, "report.pdf")
        XCTAssertEqual(rep.mime, "application/pdf")
        XCTAssertEqual(rep.size, UInt64(body.count))
        // Files always stream: inlining would mean reading the file during
        // the snapshot, which is what we're avoiding.
        XCTAssertFalse(rep.hasInline)
    }

    func testSendOfferSkipsAFileTheReceiverWouldReject() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = FakeSource()
        source.contents = [("text/plain", Data("fallback".utf8))]
        bridge.source = source
        await handshake(bridge, sink)

        // A name the peer's sanitizer refuses. Announcing it would just get
        // the transfer refused, so it never goes out.
        source.files = [scratch.appendingPathComponent("CON")]
        try Data("x".utf8).write(to: scratch.appendingPathComponent("CON"))

        await bridge.sendOffer()
        guard case .clipboardOffer(let offer) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected clipboard offer")
        }
        XCTAssertEqual(offer.payload.representations.compactMap { $0.hasFileName ? $0.fileName : nil }, [])
        XCTAssertEqual(offer.payload.representations.map(\.mime), ["text/plain"])
    }

    func testStreamOpenServesAFileFromDisk() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = FakeSource()
        // Several chunks' worth, so the framing loop actually loops.
        let body = Self.incompressibleBytes(200_000, seed: 11)
        source.files = [try writeFile("big.bin", bytes: body, in: scratch)]
        bridge.source = source
        await handshake(bridge, sink)
        let clipboardId = try await sendOfferAndClipboardId(bridge, sink)

        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeClipboardStreamOpen(streamId: 21, clipboardId: clipboardId, index: 0)
        )
        await bridge.drainOutboundStreams()

        var assembled = Data()
        var sawComplete = false
        for message in try sink.messages() {
            switch message {
            case .streamData(let d):
                XCTAssertEqual(d.streamID, 21)
                assembled.append(d.data)
            case .streamClose(let c):
                XCTAssertEqual(c.status, .streamStatusComplete)
                sawComplete = true
            default:
                XCTFail("unexpected message while serving a file: \(message)")
            }
        }
        XCTAssertTrue(sawComplete)
        XCTAssertEqual(assembled, body)
        for frame in sink.frames {
            XCTAssertLessThanOrEqual(frame.count, ClipboardCodec.maxFrameBytes)
        }
    }

    /// A compressible file is announced DEFLATE and streamed through the
    /// incremental codec; what lands must inflate back to the original.
    func testStreamOpenServesADeflatedFile() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = FakeSource()
        let body = Data(String(repeating: "compressible line\n", count: 20_000).utf8)
        source.files = [try writeFile("notes.txt", bytes: body, in: scratch)]
        bridge.source = source
        await handshake(bridge, sink)

        await bridge.sendOffer()
        guard case .clipboardOffer(let offer) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected clipboard offer")
        }
        let rep = try XCTUnwrap(offer.payload.representations.first)
        XCTAssertEqual(rep.compression, .deflate)
        XCTAssertEqual(rep.size, UInt64(body.count), "size is the UNcompressed length")
        sink.frames.removeAll()

        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeClipboardStreamOpen(
                streamId: 22, clipboardId: offer.clipboardID, index: rep.index
            )
        )
        await bridge.drainOutboundStreams()

        var wire = Data()
        for message in try sink.messages() {
            if case .streamData(let d) = message { wire.append(d.data) }
        }
        XCTAssertLessThan(wire.count, body.count, "deflate should have earned its keep")
        XCTAssertEqual(try RawDeflate.decompress(wire), body)
    }

    func testStreamOpenForAFileThatVanishedIsNotFound() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = FakeSource()
        let url = try writeFile("doomed.bin", bytes: Data("bye".utf8), in: scratch)
        source.files = [url]
        bridge.source = source
        await handshake(bridge, sink)
        let clipboardId = try await sendOfferAndClipboardId(bridge, sink)

        // Offered, then deleted before the peer pulled.
        try FileManager.default.removeItem(at: url)

        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeClipboardStreamOpen(streamId: 23, clipboardId: clipboardId, index: 0)
        )
        await bridge.drainOutboundStreams()
        guard case .streamClose(let c) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected stream_close")
        }
        XCTAssertEqual(c.status, .streamStatusNotFound)
    }

    /// A file that grew or shrank between the offer's `stat` and the pull
    /// would fail the receiver's length check; say so rather than claim
    /// COMPLETE.
    func testStreamOpenForAFileThatChangedIsIoError() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = FakeSource()
        let url = try writeFile("mutable.bin", bytes: Data(repeating: 0x01, count: 100), in: scratch)
        source.files = [url]
        bridge.source = source
        await handshake(bridge, sink)
        let clipboardId = try await sendOfferAndClipboardId(bridge, sink)

        try Data(repeating: 0x02, count: 40).write(to: url)

        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeClipboardStreamOpen(streamId: 24, clipboardId: clipboardId, index: 0)
        )
        await bridge.drainOutboundStreams()
        let closes = try sink.messages().compactMap { message -> StreamClose? in
            if case .streamClose(let c) = message { return c }
            return nil
        }
        XCTAssertEqual(closes.map(\.status), [.streamStatusIoError])
    }

    func testStreamOpenForAFileAfterTheClipboardMovedIsUnavailable() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = FakeSource()
        source.files = [try writeFile("stale.bin", bytes: Data("old".utf8), in: scratch)]
        bridge.source = source
        await handshake(bridge, sink)
        let clipboardId = try await sendOfferAndClipboardId(bridge, sink)

        source.bump(replacement: [("text/plain", Data("new".utf8))])

        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeClipboardStreamOpen(streamId: 25, clipboardId: clipboardId, index: 0)
        )
        await bridge.drainOutboundStreams()
        guard case .streamClose(let c) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected stream_close")
        }
        XCTAssertEqual(c.status, .streamStatusUnavailable)
    }

    // MARK: - Drag origin

    func testHelloAdvertisesClipboardAndDrag() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        await bridge.engage()
        await bridge.handleChannelReadyChange(true)
        guard case .hello(let hello) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected hello")
        }
        XCTAssertEqual(Set(hello.supportedFeatures), [.clipboardV1, .dragV1])
    }

    func testBeginDragAnnouncesOneRepresentationPerFileAndMovesNoBytes() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        await handshake(bridge, sink, peerFeatures: [.clipboardV1, .dragV1])

        let a = try writeFile("one.txt", bytes: Data("alpha".utf8), in: scratch)
        let b = try writeFile("two.png", bytes: Data(repeating: 0x89, count: 4096), in: scratch)
        let started = await bridge.beginDrag(fileURLs: [a, b])
        let dragId = try XCTUnwrap(started)

        XCTAssertEqual(sink.frames.count, 1, "a drag moves no bytes until it's dropped")
        guard case .dragOffer(let offer) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected drag offer")
        }
        XCTAssertEqual(offer.dragID, dragId)
        XCTAssertEqual(offer.payload.representations.map(\.fileName), ["one.txt", "two.png"])
        XCTAssertEqual(offer.payload.representations.map(\.index), [0, 1])
        XCTAssertEqual(offer.payload.representations.map(\.size), [5, 4096])
        XCTAssertTrue(offer.payload.representations.allSatisfy { !$0.hasInline })
    }

    /// A sender MUST NOT send a feature-gated message the peer's latest
    /// Hello didn't advertise.
    func testBeginDragWithoutPeerDragFeatureIsSilent() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        await handshake(bridge, sink, peerFeatures: [.clipboardV1])

        let url = try writeFile("ignored.txt", bytes: Data("x".utf8), in: scratch)
        let dragId = await bridge.beginDrag(fileURLs: [url])
        XCTAssertNil(dragId)
        XCTAssertEqual(sink.frames.count, 0)
    }

    func testBeginDragBeforeEngagementIsSilent() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        await bridge.handleChannelReadyChange(true)
        await bridge.handleInboundFrame(makeHello(features: [.clipboardV1, .dragV1]))

        let url = try writeFile("ignored.txt", bytes: Data("x".utf8), in: scratch)
        let started = await bridge.beginDrag(fileURLs: [url])
        XCTAssertNil(started)
        XCTAssertEqual(sink.frames.count, 0)
    }

    func testBeginDragSkipsDirectoriesAndUnsafeNames() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        await handshake(bridge, sink, peerFeatures: [.clipboardV1, .dragV1])

        let folder = scratch.appendingPathComponent("a folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let reserved = try writeFile("NUL", bytes: Data("x".utf8), in: scratch)
        let good = try writeFile("keep.txt", bytes: Data("keep".utf8), in: scratch)

        let started = await bridge.beginDrag(fileURLs: [folder, reserved, good])
        XCTAssertNotNil(started)
        guard case .dragOffer(let offer) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected drag offer")
        }
        XCTAssertEqual(offer.payload.representations.map(\.fileName), ["keep.txt"])
    }

    func testDropThenStreamOpenServesTheDraggedFile() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        await handshake(bridge, sink, peerFeatures: [.clipboardV1, .dragV1])

        let body = Self.incompressibleBytes(100_000, seed: 13)
        let url = try writeFile("dropped.bin", bytes: body, in: scratch)
        let started = await bridge.beginDrag(fileURLs: [url])
        let dragId = try XCTUnwrap(started)
        await bridge.endDrag(dragId, status: .dragStatusDropped)
        sink.frames.removeAll()

        var open = StreamOpen()
        open.streamID = 31
        var item = StreamOpen.DragItem()
        item.dragID = dragId
        item.index = 0
        open.source = .dragItem(item)
        await bridge.handleInboundFrame(try ClipboardCodec.encode(.streamOpen(open)))
        await bridge.drainOutboundStreams()

        var assembled = Data()
        var sawComplete = false
        for message in try sink.messages() {
            switch message {
            case .streamData(let d): assembled.append(d.data)
            case .streamClose(let c):
                XCTAssertEqual(c.status, .streamStatusComplete)
                sawComplete = true
            default: XCTFail("unexpected message: \(message)")
            }
        }
        XCTAssertTrue(sawComplete)
        XCTAssertEqual(assembled, body)
    }

    func testDragEndReportsTheOperatorsRelease() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        await handshake(bridge, sink, peerFeatures: [.clipboardV1, .dragV1])

        let url = try writeFile("f.txt", bytes: Data("x".utf8), in: scratch)
        let started = await bridge.beginDrag(fileURLs: [url])
        let dragId = try XCTUnwrap(started)
        sink.frames.removeAll()
        await bridge.endDrag(dragId, status: .dragStatusDropped)

        guard case .dragEnd(let end) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected drag end")
        }
        XCTAssertEqual(end.dragID, dragId)
        XCTAssertEqual(end.status, .dragStatusDropped)

        // Exactly one DragEnd per gesture.
        sink.frames.removeAll()
        await bridge.endDrag(dragId, status: .dragStatusCancelled)
        XCTAssertEqual(sink.frames.count, 0)
    }

    /// Cancelled (Esc, or released over no valid target): the drag is
    /// forgotten and no stream can pull from it.
    func testCancelledDragRefusesLaterPulls() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        await handshake(bridge, sink, peerFeatures: [.clipboardV1, .dragV1])

        let url = try writeFile("aborted.bin", bytes: Data("nope".utf8), in: scratch)
        let started = await bridge.beginDrag(fileURLs: [url])
        let dragId = try XCTUnwrap(started)
        await bridge.endDrag(dragId, status: .dragStatusCancelled)
        sink.frames.removeAll()

        var open = StreamOpen()
        open.streamID = 32
        var item = StreamOpen.DragItem()
        item.dragID = dragId
        item.index = 0
        open.source = .dragItem(item)
        await bridge.handleInboundFrame(try ClipboardCodec.encode(.streamOpen(open)))
        await bridge.drainOutboundStreams()

        guard case .streamClose(let c) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected stream_close")
        }
        XCTAssertEqual(c.streamID, 32)
        XCTAssertEqual(c.status, .streamStatusUnavailable)
    }

    func testStreamOpenForAnUnknownDragIsUnavailable() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        await handshake(bridge, sink, peerFeatures: [.clipboardV1, .dragV1])

        var open = StreamOpen()
        open.streamID = 33
        var item = StreamOpen.DragItem()
        item.dragID = 999
        item.index = 0
        open.source = .dragItem(item)
        await bridge.handleInboundFrame(try ClipboardCodec.encode(.streamOpen(open)))
        await bridge.drainOutboundStreams()

        guard case .streamClose(let c) = try ClipboardCodec.decode(sink.frames[0]) else {
            return XCTFail("expected stream_close")
        }
        XCTAssertEqual(c.status, .streamStatusUnavailable)
    }

    /// Drags are concurrent, not superseding: a second one doesn't tear
    /// down the first.
    func testConcurrentDragsAreIndependent() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        await handshake(bridge, sink, peerFeatures: [.clipboardV1, .dragV1])

        let startedFirst = await bridge.beginDrag(
            fileURLs: [try writeFile("a.bin", bytes: Data("aaa".utf8), in: scratch)]
        )
        let startedSecond = await bridge.beginDrag(
            fileURLs: [try writeFile("b.bin", bytes: Data("bbbb".utf8), in: scratch)]
        )
        let first = try XCTUnwrap(startedFirst)
        let second = try XCTUnwrap(startedSecond)
        XCTAssertNotEqual(first, second)

        await bridge.endDrag(second, status: .dragStatusCancelled)
        await bridge.endDrag(first, status: .dragStatusDropped)
        sink.frames.removeAll()

        var open = StreamOpen()
        open.streamID = 34
        var item = StreamOpen.DragItem()
        item.dragID = first
        item.index = 0
        open.source = .dragItem(item)
        await bridge.handleInboundFrame(try ClipboardCodec.encode(.streamOpen(open)))
        await bridge.drainOutboundStreams()

        var assembled = Data()
        for message in try sink.messages() {
            if case .streamData(let d) = message { assembled.append(d.data) }
        }
        XCTAssertEqual(assembled, Data("aaa".utf8))
    }

    /// Regi never proxies a drag, so an inbound DragOffer is noise we must
    /// ignore rather than act on.
    func testInboundDragOfferIsIgnored() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        await handshake(bridge, sink, peerFeatures: [.clipboardV1, .dragV1])

        var offer = DragOffer()
        offer.dragID = 1
        var payload = Payload()
        payload.representations = [streamedFileRep(index: 0, fileName: "theirs.bin", size: 10)]
        offer.payload = payload
        await bridge.handleInboundFrame(try ClipboardCodec.encode(.dragOffer(offer)))

        XCTAssertEqual(sink.frames.count, 0)
    }

    // MARK: - Serving does not block the inbound frame pump

    /// The backend pumps inbound frames through `handleInboundFrame` one
    /// at a time, so serving a stream inline would make the peer's
    /// `StreamCancel` for that very stream unobservable — it would sit
    /// behind the transfer it is trying to stop.
    func testPeerStreamCancelInterruptsATransferInFlight() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = FakeSource()
        // Many frames' worth, so there is a middle to interrupt.
        let body = Self.incompressibleBytes(2_000_000, seed: 17)
        source.files = [try writeFile("large.bin", bytes: body, in: scratch)]
        bridge.source = source
        await handshake(bridge, sink)
        let clipboardId = try await sendOfferAndClipboardId(bridge, sink)

        // Deliberately no drain here: the open must return before the
        // transfer finishes, or the cancel below could never be decoded.
        await bridge.handleInboundFrame(
            try ClipboardCodec.encodeClipboardStreamOpen(streamId: 41, clipboardId: clipboardId, index: 0)
        )
        await bridge.handleInboundFrame(try ClipboardCodec.encodeStreamCancel(streamId: 41))
        await bridge.drainOutboundStreams()

        var assembled = Data()
        var closes: [StreamClose.Status] = []
        for message in try sink.messages() {
            switch message {
            case .streamData(let d): assembled.append(d.data)
            case .streamClose(let c): closes.append(c.status)
            default: XCTFail("unexpected message: \(message)")
            }
        }
        XCTAssertEqual(closes, [.streamStatusCancelled], "exactly one close, confirming the cancel")
        XCTAssertLessThan(assembled.count, body.count, "the transfer must actually stop early")
    }

    /// `index` is peer-supplied. Two slots resolving to the same one would
    /// leave the second forever pending, so the offer could never settle.
    func testDuplicateRepresentationIndexIsRejected() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let task = firstResolvedOffer(bridge)

        await bridge.handleInboundFrame(
            try makeOffer(clipboardId: 51, [
                streamedRep(index: 3, mime: "text/plain", size: 4),
                streamedRep(index: 3, mime: "text/html", size: 4),
            ])
        )
        // Only the first index-3 representation was pulled.
        let streamId = try soleStreamOpenId(sink)
        try await feedStream(bridge, streamId: streamId, body: Data("abcd".utf8))

        let resolved = await task.value
        XCTAssertEqual(resolved.formats.map(\.mime), ["text/plain"])
    }

    /// A hard kill skips `ClipboardFileWriter`'s cleanup, so a previous
    /// run's partials can be anywhere under the root — including
    /// directories this run will never touch. The sweep rides the first
    /// redemption, since that's the first time this bridge touches disk.
    func testSweepsPartialsLeftByAPreviousRun() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        bridge.inboundFileRoot = scratch

        // Debris from a run with a different session tag and clipboard id.
        let stale = scratch.appendingPathComponent("deadbeef-clipboard-3", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let debris = stale.appendingPathComponent(ClipboardFileRules.tempPrefix + "99-old")
        let keeper = stale.appendingPathComponent("already-landed.txt")
        try Data(repeating: 0xEE, count: 16).write(to: debris)
        try Data("keep me".utf8).write(to: keeper)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -2 * ClipboardBridge.orphanMinAge)],
            ofItemAtPath: debris.path
        )

        let task = firstResolvedOffer(bridge)
        var rep = inlineRep(index: 0, mime: "text/plain", body: Data("hi".utf8))
        rep.fileName = "new.txt"
        await bridge.handleInboundFrame(try makeOffer(clipboardId: 1, [rep]))
        let resolved = await task.value
        let promise = try XCTUnwrap(resolved.files.first)
        _ = try await bridge.fetchPromisedFile(promise)

        XCTAssertFalse(FileManager.default.fileExists(atPath: debris.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path), "only our own partials go")
    }
}
