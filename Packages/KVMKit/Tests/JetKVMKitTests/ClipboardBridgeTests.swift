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
    }

    /// In-memory ClipboardSource the tests can mutate between bridge
    /// calls to simulate the local clipboard moving on.
    final class FakeSource: ClipboardSource, @unchecked Sendable {
        var currentToken: Int = 1
        var contents: [String: Data] = [:]

        func snapshot() async -> ClipboardSnapshot {
            let formats = contents
                .map { ClipboardFormatDescriptor(mime: $0.key, size: UInt64($0.value.count)) }
            return ClipboardSnapshot(
                token: ClipboardSnapshotToken(currentToken),
                formats: formats
            )
        }

        func fetchData(mime: String, token: ClipboardSnapshotToken) async -> Data? {
            guard token.value == currentToken else { return nil }
            return contents[mime]
        }

        /// Simulates the user copying something new.
        func bump(replacement: [String: Data]) {
            currentToken += 1
            contents = replacement
        }
    }

    private func makeBridge(sink: CapturingSink) -> ClipboardBridge {
        ClipboardBridge { [weak sink] data in
            await sink?.send(data) ?? false
        }
    }

    private func makeHello(compressions: [Compression] = [.none, .deflate]) -> Data {
        try! ClipboardCodec.encodeHello(
            compressions: compressions,
            features: [.clipboardWriteV1]
        )
    }

    // MARK: - Channel readiness + engagement

    func testChannelReadyWithoutEngagementIsSilent() async {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        await bridge.handleChannelReadyChange(true)
        // No Hello should fly — Regi is client-initiated, the bridge
        // stays silent on the wire until engage() is called.
        XCTAssertEqual(sink.frames.count, 0)
    }

    func testEngageBeforeChannelReadyDefersHello() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        await bridge.engage()
        // Channel isn't open yet — engage() can't ship a Hello.
        XCTAssertEqual(sink.frames.count, 0)
        // When the channel becomes ready, the deferred Hello fires.
        await bridge.handleChannelReadyChange(true)
        XCTAssertEqual(sink.frames.count, 1)
        let decoded = try ClipboardCodec.decode(sink.frames[0])
        guard case .hello = decoded else { return XCTFail("expected hello") }
    }

    func testEngageWhileChannelReadySendsHelloImmediately() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        await bridge.handleChannelReadyChange(true)
        XCTAssertEqual(sink.frames.count, 0)
        await bridge.engage()
        XCTAssertEqual(sink.frames.count, 1)
        let decoded = try ClipboardCodec.decode(sink.frames[0])
        guard case .hello(let h) = decoded else {
            return XCTFail("expected hello, got \(decoded)")
        }
        XCTAssertEqual(h.compressions, [.none, .deflate])
        XCTAssertEqual(h.supportedFeatures, [.clipboardWriteV1])
    }

    func testEngageIsIdempotent() async {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        await bridge.handleChannelReadyChange(true)
        await bridge.engage()
        await bridge.engage()  // second call no-op
        await bridge.engage()
        XCTAssertEqual(sink.frames.count, 1)
    }

    func testChannelCycleReEngagedReHellos() async {
        // While engaged, every channel-ready transition re-initiates
        // the Hello dance — peerHello cleared on close, so we want a
        // fresh exchange on reopen.
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
        XCTAssertEqual(sink.frames.count, 1)
        bridge.disengage()
        await bridge.handleChannelReadyChange(false)
        await bridge.handleChannelReadyChange(true)
        // No new Hello after disengage.
        XCTAssertEqual(sink.frames.count, 1)
    }

    // MARK: - Inbound

    func testInboundTextOnlyOfferYields() async {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)

        // Pump receives offers regardless of whether peerHello arrived.
        var inline = ClipboardOfferV1.InlineData()
        inline.compression = .none
        inline.data = Data("hello".utf8)
        var format = ClipboardOfferV1.Format()
        format.mime = "text/plain"
        format.inline = inline
        var offer = ClipboardOfferV1()
        offer.offerID = 1
        offer.formats = [format]

        let task = Task { [bridge] in
            for await resolved in await bridge.inboundOffers {
                return resolved
            }
            return ResolvedOffer(offerId: 0, formats: [])
        }

        await bridge.handleInboundFrame(try! ClipboardCodec.encodeOffer(offer))
        let resolved = await task.value
        XCTAssertEqual(resolved.offerId, 1)
        XCTAssertEqual(resolved.formats, [ResolvedFormat(mime: "text/plain", data: Data("hello".utf8))])
    }

    func testInboundDeflatedInlineDecompressed() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let text = String(repeating: "abc ", count: 200)  // ~800 chars; deflate-friendly
        let compressed = try RawDeflate.compress(Data(text.utf8))

        var inline = ClipboardOfferV1.InlineData()
        inline.compression = .deflate
        inline.data = compressed
        var format = ClipboardOfferV1.Format()
        format.mime = "text/plain;charset=utf-8"
        format.inline = inline
        var offer = ClipboardOfferV1()
        offer.offerID = 7
        offer.formats = [format]

        let task = Task { [bridge] in
            for await resolved in await bridge.inboundOffers { return resolved }
            return ResolvedOffer(offerId: 0, formats: [])
        }
        await bridge.handleInboundFrame(try ClipboardCodec.encodeOffer(offer))
        let resolved = await task.value
        XCTAssertEqual(resolved.formats.first?.data, Data(text.utf8))
    }

    func testInboundMixedOfferIssuesRequestAndResolvesOnResponse() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)

        // Inline text + size_hint image.
        var inline = ClipboardOfferV1.InlineData()
        inline.compression = .none
        inline.data = Data("preview".utf8)
        var textFmt = ClipboardOfferV1.Format()
        textFmt.mime = "text/plain"
        textFmt.inline = inline

        var imgFmt = ClipboardOfferV1.Format()
        imgFmt.mime = "image/png"
        imgFmt.sizeHint = 5_000_000

        var offer = ClipboardOfferV1()
        offer.offerID = 42
        offer.formats = [textFmt, imgFmt]

        let task = Task { [bridge] in
            for await resolved in await bridge.inboundOffers { return resolved }
            return ResolvedOffer(offerId: 0, formats: [])
        }

        await bridge.handleInboundFrame(try ClipboardCodec.encodeOffer(offer))

        // Bridge should have shipped exactly one ClipboardRequestV1 for image/png.
        XCTAssertEqual(sink.frames.count, 1, "expected a single ClipboardRequestV1 ship")
        if let req = sink.frames.first {
            let decoded = try ClipboardCodec.decode(req)
            guard case .request(let r) = decoded else {
                return XCTFail("expected request, got \(decoded)")
            }
            XCTAssertEqual(r.offerID, 42)
            XCTAssertEqual(r.mime, "image/png")
        }

        // Feed the bridge a matching response with PNG bytes.
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var resp = ClipboardResponseV1()
        resp.offerID = 42
        resp.mime = "image/png"
        resp.status = .ok
        resp.compression = .none
        resp.data = pngBytes
        await bridge.handleInboundFrame(try ClipboardCodec.encodeResponse(resp))

        let resolved = await task.value
        XCTAssertEqual(resolved.offerId, 42)
        // Order: inline format resolved first, then the fetched one.
        XCTAssertEqual(resolved.formats.count, 2)
        XCTAssertTrue(resolved.formats.contains(where: { $0.mime == "text/plain" && $0.data == Data("preview".utf8) }))
        XCTAssertTrue(resolved.formats.contains(where: { $0.mime == "image/png" && $0.data == pngBytes }))
    }

    func testInboundOfferUnacceptedMimeIsDropped() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)

        var bogus = ClipboardOfferV1.InlineData()
        bogus.compression = .none
        bogus.data = Data("nope".utf8)
        var bogusFmt = ClipboardOfferV1.Format()
        bogusFmt.mime = "application/x-vendor-thing"
        bogusFmt.inline = bogus

        var okInline = ClipboardOfferV1.InlineData()
        okInline.compression = .none
        okInline.data = Data("yes".utf8)
        var okFmt = ClipboardOfferV1.Format()
        okFmt.mime = "text/plain"
        okFmt.inline = okInline

        var offer = ClipboardOfferV1()
        offer.offerID = 9
        offer.formats = [bogusFmt, okFmt]

        let task = Task { [bridge] in
            for await resolved in await bridge.inboundOffers { return resolved }
            return ResolvedOffer(offerId: 0, formats: [])
        }
        await bridge.handleInboundFrame(try ClipboardCodec.encodeOffer(offer))
        let resolved = await task.value
        XCTAssertEqual(resolved.formats.map(\.mime), ["text/plain"])
    }

    func testInboundUnsupportedVersionDoesNotCrash() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        var envelope = Envelope()
        envelope.version = 2
        var hello = Hello()
        hello.protocolVersion = 2
        envelope.message = .hello(hello)
        let bogus: Data = try envelope.serializedBytes()
        // Bridge logs + drops; no yield, no crash.
        await bridge.handleInboundFrame(bogus)
        XCTAssertEqual(sink.frames.count, 0)
    }

    // MARK: - Outbound

    func testSendOfferWithoutPeerHelloIsNoop() async {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        source.contents = ["text/plain": Data("hello".utf8)]
        bridge.source = source

        await bridge.sendOffer()
        XCTAssertEqual(sink.frames.count, 0)
    }

    func testSendOfferInlinesSmallText() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        source.contents = ["text/plain": Data("hello".utf8)]
        bridge.source = source

        // Engage + ship + receive the peer's hello first.
        await bridge.engage()
        await bridge.handleChannelReadyChange(true)
        await bridge.handleInboundFrame(makeHello())
        sink.frames.removeAll()  // drop our own hello

        await bridge.sendOffer()
        XCTAssertEqual(sink.frames.count, 1)
        let decoded = try ClipboardCodec.decode(sink.frames[0])
        guard case .offer(let o) = decoded else { return XCTFail("expected offer") }
        XCTAssertEqual(o.formats.count, 1)
        XCTAssertEqual(o.formats[0].mime, "text/plain")
        guard case .inline(let inline) = o.formats[0].body else { return XCTFail("expected inline") }
        XCTAssertEqual(inline.compression, .none)  // "hello" is 5 bytes, below deflateMinSize
        XCTAssertEqual(inline.data, Data("hello".utf8))
    }

    func testSendOfferDeflatesLargeTextWhenPeerSupportsIt() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        let payload = String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 50)
        source.contents = ["text/plain": Data(payload.utf8)]
        bridge.source = source

        await bridge.engage()
        await bridge.handleChannelReadyChange(true)
        await bridge.handleInboundFrame(makeHello())
        sink.frames.removeAll()

        await bridge.sendOffer()
        let decoded = try ClipboardCodec.decode(sink.frames[0])
        guard case .offer(let o) = decoded else { return XCTFail() }
        guard case .inline(let inline) = o.formats[0].body else { return XCTFail() }
        XCTAssertEqual(inline.compression, .deflate)
        // Round-trip the inline data and check.
        let restored = try RawDeflate.decompress(inline.data)
        XCTAssertEqual(restored, Data(payload.utf8))
    }

    func testSendOfferLargeUsesSizeHint() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        // 100 KiB > 64 KiB threshold; image/png is binary so no compression
        // matters — should be advertised by size_hint.
        let bigPng = Data(repeating: 0xAB, count: 100 * 1024)
        source.contents = ["image/png": bigPng]
        bridge.source = source

        await bridge.engage()
        await bridge.handleChannelReadyChange(true)
        await bridge.handleInboundFrame(makeHello())
        sink.frames.removeAll()

        await bridge.sendOffer()
        let decoded = try ClipboardCodec.decode(sink.frames[0])
        guard case .offer(let o) = decoded else { return XCTFail() }
        XCTAssertEqual(o.formats[0].mime, "image/png")
        guard case .sizeHint(let n) = o.formats[0].body else { return XCTFail("expected sizeHint, got \(o.formats[0].body as Any)") }
        XCTAssertEqual(n, UInt64(bigPng.count))
    }

    // MARK: - Outbound request handling

    func testInboundRequestServedFromCurrentSnapshot() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        let bigPng = Data(repeating: 0x42, count: 100 * 1024)
        source.contents = ["image/png": bigPng]
        bridge.source = source

        await bridge.engage()
        await bridge.handleChannelReadyChange(true)
        await bridge.handleInboundFrame(makeHello())
        sink.frames.removeAll()
        await bridge.sendOffer()
        // The shipped offer carries an offer_id we need to echo.
        let offerEnvelope = try ClipboardCodec.decode(sink.frames[0])
        guard case .offer(let outbound) = offerEnvelope else { return XCTFail() }
        sink.frames.removeAll()

        var req = ClipboardRequestV1()
        req.offerID = outbound.offerID
        req.mime = "image/png"
        await bridge.handleInboundFrame(try ClipboardCodec.encodeRequest(offerId: req.offerID, mime: req.mime))

        XCTAssertEqual(sink.frames.count, 1)
        let respEnv = try ClipboardCodec.decode(sink.frames[0])
        guard case .response(let resp) = respEnv else { return XCTFail() }
        XCTAssertEqual(resp.status, .ok)
        XCTAssertEqual(resp.data, bigPng)
    }

    func testInboundRequestForStaleOfferReturnsUnavailable() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        source.contents = ["image/png": Data(repeating: 0x42, count: 100 * 1024)]
        bridge.source = source

        await bridge.engage()
        await bridge.handleChannelReadyChange(true)
        await bridge.handleInboundFrame(makeHello())
        sink.frames.removeAll()
        await bridge.sendOffer()
        let offerEnv = try ClipboardCodec.decode(sink.frames[0])
        guard case .offer(let outbound) = offerEnv else { return XCTFail() }
        sink.frames.removeAll()

        // Local clipboard moves on. The request still references the old
        // offer_id but our snapshot token has advanced; the bridge must
        // reply STATUS_UNAVAILABLE.
        source.bump(replacement: ["text/plain": Data("new".utf8)])

        await bridge.handleInboundFrame(try ClipboardCodec.encodeRequest(offerId: outbound.offerID, mime: "image/png"))
        XCTAssertEqual(sink.frames.count, 1)
        let respEnv = try ClipboardCodec.decode(sink.frames[0])
        guard case .response(let resp) = respEnv else { return XCTFail() }
        XCTAssertEqual(resp.status, .unavailable)
    }

    func testInboundRequestForUnknownOfferIdReturnsUnavailable() async throws {
        let sink = CapturingSink()
        let bridge = makeBridge(sink: sink)
        let source = FakeSource()
        source.contents = ["image/png": Data([0xAB])]
        bridge.source = source

        await bridge.engage()
        await bridge.handleChannelReadyChange(true)
        await bridge.handleInboundFrame(makeHello())
        sink.frames.removeAll()

        // We never sent an offer; any request is by definition stale.
        await bridge.handleInboundFrame(try ClipboardCodec.encodeRequest(offerId: 999, mime: "image/png"))
        XCTAssertEqual(sink.frames.count, 1)
        let respEnv = try ClipboardCodec.decode(sink.frames[0])
        guard case .response(let resp) = respEnv else { return XCTFail() }
        XCTAssertEqual(resp.status, .unavailable)
    }
}
