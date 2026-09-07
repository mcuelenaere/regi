import XCTest
@testable import JetKVMKit

final class ClipboardCodecTests: XCTestCase {

    // MARK: - Hello

    func testRoundTripHello() throws {
        var hello = Hello()
        hello.userAgent = "regi/test"
        hello.supportedCompressions = [.none, .deflate]
        hello.supportedFeatures = [.clipboardV1]

        let frame = try ClipboardCodec.encode(.hello(hello))
        let decoded = try ClipboardCodec.decode(frame)
        guard case .hello(let h) = decoded else {
            return XCTFail("expected .hello, got \(decoded)")
        }
        XCTAssertEqual(h, hello)
    }

    func testEncodeHelloConvenience() throws {
        let frame = try ClipboardCodec.encodeHello(
            userAgent: "regi/1.2",
            compressions: [.none, .deflate],
            features: [.clipboardV1]
        )
        let decoded = try ClipboardCodec.decode(frame)
        guard case .hello(let h) = decoded else {
            return XCTFail("expected .hello, got \(decoded)")
        }
        XCTAssertEqual(h.userAgent, "regi/1.2")
        XCTAssertEqual(h.supportedCompressions, [.none, .deflate])
        XCTAssertEqual(h.supportedFeatures, [.clipboardV1])
    }

    // MARK: - Clipboard offer

    func testRoundTripOfferInline() throws {
        var rep = Representation()
        rep.index = 0
        rep.mime = "text/plain;charset=utf-8"
        rep.size = 5
        rep.compression = .none
        rep.inline = Data("hello".utf8)

        var payload = Payload()
        payload.representations = [rep]
        var offer = ClipboardOffer()
        offer.clipboardID = 1
        offer.payload = payload

        let frame = try ClipboardCodec.encodeClipboardOffer(offer)
        let decoded = try ClipboardCodec.decode(frame)
        guard case .clipboardOffer(let o) = decoded else {
            return XCTFail("expected .clipboardOffer, got \(decoded)")
        }
        XCTAssertEqual(o, offer)
        XCTAssertTrue(o.payload.representations[0].hasInline)
    }

    /// `inline` absent is the signal to stream — it must survive the
    /// round-trip as *absent*, not as empty bytes (which would mean
    /// "apply an empty representation directly").
    func testRoundTripOfferStreamedRepresentationOmitsInline() throws {
        var rep = Representation()
        rep.index = 0
        rep.mime = "image/png"
        rep.size = 1_500_000
        rep.compression = .none

        var payload = Payload()
        payload.representations = [rep]
        var offer = ClipboardOffer()
        offer.clipboardID = 42
        offer.payload = payload

        let frame = try ClipboardCodec.encodeClipboardOffer(offer)
        let decoded = try ClipboardCodec.decode(frame)
        guard case .clipboardOffer(let o) = decoded else {
            return XCTFail("expected .clipboardOffer, got \(decoded)")
        }
        XCTAssertFalse(o.payload.representations[0].hasInline)
        XCTAssertEqual(o.payload.representations[0].size, 1_500_000)
    }

    /// An empty inline body is distinct from an absent one.
    func testEmptyInlineIsDistinctFromAbsent() throws {
        var rep = Representation()
        rep.index = 0
        rep.mime = "text/plain"
        rep.size = 0
        rep.compression = .none
        rep.inline = Data()

        var payload = Payload()
        payload.representations = [rep]
        var offer = ClipboardOffer()
        offer.clipboardID = 3
        offer.payload = payload

        let frame = try ClipboardCodec.encodeClipboardOffer(offer)
        guard case .clipboardOffer(let o) = try ClipboardCodec.decode(frame) else {
            return XCTFail("expected .clipboardOffer")
        }
        XCTAssertTrue(o.payload.representations[0].hasInline)
        XCTAssertTrue(o.payload.representations[0].inline.isEmpty)
    }

    func testRoundTripFileRepresentation() throws {
        var rep = Representation()
        rep.index = 1
        rep.fileName = "note.txt"
        rep.mime = "text/plain"
        rep.size = 12
        rep.compression = .none

        var payload = Payload()
        payload.representations = [rep]
        var offer = ClipboardOffer()
        offer.clipboardID = 8
        offer.payload = payload

        let frame = try ClipboardCodec.encodeClipboardOffer(offer)
        guard case .clipboardOffer(let o) = try ClipboardCodec.decode(frame) else {
            return XCTFail("expected .clipboardOffer")
        }
        XCTAssertTrue(o.payload.representations[0].hasFileName)
        XCTAssertEqual(o.payload.representations[0].fileName, "note.txt")
    }

    // MARK: - Streaming layer

    func testRoundTripStreamOpenClipboardItem() throws {
        let frame = try ClipboardCodec.encodeClipboardStreamOpen(
            streamId: 7,
            clipboardId: 42,
            index: 3
        )
        let decoded = try ClipboardCodec.decode(frame)
        guard case .streamOpen(let open) = decoded else {
            return XCTFail("expected .streamOpen, got \(decoded)")
        }
        XCTAssertEqual(open.streamID, 7)
        guard case .clipboardItem(let item) = open.source else {
            return XCTFail("expected clipboardItem source")
        }
        XCTAssertEqual(item.clipboardID, 42)
        XCTAssertEqual(item.index, 3)
    }

    func testRoundTripStreamData() throws {
        let payload = Data([0x01, 0x02, 0x03])
        let frame = try ClipboardCodec.encodeStreamData(streamId: 9, data: payload)
        guard case .streamData(let d) = try ClipboardCodec.decode(frame) else {
            return XCTFail("expected .streamData")
        }
        XCTAssertEqual(d.streamID, 9)
        XCTAssertEqual(d.data, payload)
    }

    func testRoundTripStreamClose() throws {
        let frame = try ClipboardCodec.encodeStreamClose(
            streamId: 4,
            status: .streamStatusComplete
        )
        guard case .streamClose(let c) = try ClipboardCodec.decode(frame) else {
            return XCTFail("expected .streamClose")
        }
        XCTAssertEqual(c.streamID, 4)
        XCTAssertEqual(c.status, .streamStatusComplete)
    }

    func testRoundTripStreamCancel() throws {
        let frame = try ClipboardCodec.encodeStreamCancel(streamId: 11)
        guard case .streamCancel(let c) = try ClipboardCodec.decode(frame) else {
            return XCTFail("expected .streamCancel")
        }
        XCTAssertEqual(c.streamID, 11)
    }

    /// A full-size StreamData frame must stay under the relay's hard
    /// 64 KiB cap once the envelope is wrapped around it.
    func testMaxChunkStreamDataFitsFrameCap() throws {
        let chunk = Data(repeating: 0xAB, count: ClipboardBridge.streamChunkBytes)
        let frame = try ClipboardCodec.encodeStreamData(streamId: 65_535, data: chunk)
        XCTAssertLessThanOrEqual(frame.count, ClipboardCodec.maxFrameBytes)
    }

    // MARK: - Error paths

    func testDecodeUnsupportedVersionThrows() throws {
        var envelope = Envelope()
        envelope.version = 2
        envelope.message = .hello(Hello())
        let bogus: Data = try envelope.serializedBytes()

        XCTAssertThrowsError(try ClipboardCodec.decode(bogus)) { error in
            XCTAssertEqual(error as? ClipboardCodecError, .unsupportedVersion(2))
        }
    }

    func testDecodeMissingMessageOneofThrows() throws {
        var envelope = Envelope()
        envelope.version = 1
        // message oneof intentionally unset
        let bogus: Data = try envelope.serializedBytes()

        XCTAssertThrowsError(try ClipboardCodec.decode(bogus)) { error in
            XCTAssertEqual(error as? ClipboardCodecError, .missingMessage)
        }
    }

    func testEncodeAlwaysSetsWireVersion() throws {
        // No matter what message we encode, the envelope's version must
        // be 1 — a version=0 envelope would be rejected by the peer.
        let frame = try ClipboardCodec.encodeStreamCancel(streamId: 1)
        let envelope = try Envelope(serializedBytes: frame)
        XCTAssertEqual(envelope.version, 1)
    }

    func testUnknownCompressionEnumPreserved() throws {
        // Proto3 preserves unrecognised enum numerics. The spec says a
        // receiver MUST treat an unknown value as a decode failure for
        // that stream; here we just assert the codec doesn't crash and
        // surfaces something that isn't a codec we'd act on.
        var rep = Representation()
        rep.index = 0
        rep.mime = "text/plain"
        rep.compression = Compression(rawValue: 99) ?? .unspecified
        rep.inline = Data([0x01])

        var payload = Payload()
        payload.representations = [rep]
        var offer = ClipboardOffer()
        offer.clipboardID = 1
        offer.payload = payload

        let frame = try ClipboardCodec.encodeClipboardOffer(offer)
        guard case .clipboardOffer(let o) = try ClipboardCodec.decode(frame) else {
            return XCTFail("expected .clipboardOffer")
        }
        let comp = o.payload.representations.first?.compression
        XCTAssertNotEqual(comp, .deflate)
        XCTAssertNotEqual(comp, .none)
    }
}
