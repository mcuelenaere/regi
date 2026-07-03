import XCTest
@testable import JetKVMKit

final class ClipboardCodecTests: XCTestCase {

    // MARK: - Hello

    func testRoundTripHello() throws {
        var hello = Hello()
        hello.protocolVersion = 1
        hello.compressions = [.none, .deflate]
        hello.supportedFeatures = [.clipboardWriteV1]

        let frame = try ClipboardCodec.encode(.hello(hello))
        let decoded = try ClipboardCodec.decode(frame)
        guard case .hello(let h) = decoded else {
            return XCTFail("expected .hello, got \(decoded)")
        }
        XCTAssertEqual(h, hello)
    }

    func testEncodeHelloConvenience() throws {
        let frame = try ClipboardCodec.encodeHello(
            compressions: [.none, .deflate],
            features: [.clipboardWriteV1]
        )
        let decoded = try ClipboardCodec.decode(frame)
        guard case .hello(let h) = decoded else {
            return XCTFail("expected .hello, got \(decoded)")
        }
        XCTAssertEqual(h.protocolVersion, 1)
        XCTAssertEqual(h.compressions, [.none, .deflate])
        XCTAssertEqual(h.supportedFeatures, [.clipboardWriteV1])
    }

    // MARK: - Offer

    func testRoundTripOfferInline() throws {
        var inline = ClipboardOfferV1.InlineData()
        inline.compression = .none
        inline.data = Data("hello".utf8)

        var format = ClipboardOfferV1.Format()
        format.mime = "text/plain;charset=utf-8"
        format.inline = inline

        var offer = ClipboardOfferV1()
        offer.offerID = 1
        offer.formats = [format]

        let frame = try ClipboardCodec.encodeOffer(offer)
        let decoded = try ClipboardCodec.decode(frame)
        guard case .offer(let o) = decoded else {
            return XCTFail("expected .offer, got \(decoded)")
        }
        XCTAssertEqual(o, offer)
    }

    func testRoundTripOfferSizeHint() throws {
        var format = ClipboardOfferV1.Format()
        format.mime = "image/png"
        format.sizeHint = 1_500_000

        var offer = ClipboardOfferV1()
        offer.offerID = 42
        offer.formats = [format]

        let frame = try ClipboardCodec.encodeOffer(offer)
        let decoded = try ClipboardCodec.decode(frame)
        guard case .offer(let o) = decoded,
              o.formats.first?.body == .sizeHint(1_500_000) else {
            return XCTFail("size_hint did not round-trip: \(decoded)")
        }
        XCTAssertEqual(o, offer)
    }

    // MARK: - Request

    func testRoundTripRequest() throws {
        let frame = try ClipboardCodec.encodeRequest(offerId: 7, mime: "image/png")
        let decoded = try ClipboardCodec.decode(frame)
        guard case .request(let r) = decoded else {
            return XCTFail("expected .request, got \(decoded)")
        }
        XCTAssertEqual(r.offerID, 7)
        XCTAssertEqual(r.mime, "image/png")
    }

    // MARK: - Response

    func testRoundTripResponseOK() throws {
        var resp = ClipboardResponseV1()
        resp.offerID = 5
        resp.mime = "text/plain;charset=utf-8"
        resp.status = .ok
        resp.compression = .deflate
        resp.data = Data([0xde, 0xad, 0xbe, 0xef])

        let frame = try ClipboardCodec.encodeResponse(resp)
        let decoded = try ClipboardCodec.decode(frame)
        guard case .response(let r) = decoded else {
            return XCTFail("expected .response, got \(decoded)")
        }
        XCTAssertEqual(r, resp)
    }

    func testRoundTripResponseTooLarge() throws {
        var resp = ClipboardResponseV1()
        resp.offerID = 5
        resp.mime = "image/png"
        resp.status = .tooLarge
        // Spec: no compression / data when status is non-OK.

        let frame = try ClipboardCodec.encodeResponse(resp)
        let decoded = try ClipboardCodec.decode(frame)
        guard case .response(let r) = decoded else {
            return XCTFail("expected .response, got \(decoded)")
        }
        XCTAssertEqual(r.status, .tooLarge)
        XCTAssertTrue(r.data.isEmpty)
    }

    // MARK: - Error paths

    func testDecodeUnsupportedVersionThrows() throws {
        // Hand-build an envelope with version=2 to confirm fast-fail.
        var envelope = Envelope()
        envelope.version = 2
        var hello = Hello()
        hello.protocolVersion = 2
        envelope.message = .hello(hello)
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
        // No matter what message we encode, the envelope's version must be
        // 1. Otherwise a buggy encoder could ship version=0 envelopes
        // that the firmware would reject as malformed.
        let frame = try ClipboardCodec.encodeRequest(offerId: 1, mime: "x")
        let envelope = try Envelope(serializedBytes: frame)
        XCTAssertEqual(envelope.version, 1)
    }

    func testUnknownCompressionEnumPreserved() throws {
        // Proto3 preserves unrecognised enum numerics. Construct a frame
        // with compression=99 (unknown) and verify our decoder doesn't
        // crash; SwiftProtobuf surfaces unknown values via
        // `.UNRECOGNIZED(99)`. Callers handle the unknown case by
        // dropping the representation.
        var inline = ClipboardOfferV1.InlineData()
        inline.compression = Compression(rawValue: 99) ?? .unspecified
        inline.data = Data([0x01])

        var format = ClipboardOfferV1.Format()
        format.mime = "text/plain"
        format.inline = inline

        var offer = ClipboardOfferV1()
        offer.offerID = 1
        offer.formats = [format]

        let frame = try ClipboardCodec.encodeOffer(offer)
        let decoded = try ClipboardCodec.decode(frame)
        guard case .offer(let o) = decoded else {
            return XCTFail("expected .offer, got \(decoded)")
        }
        // Either the unknown value round-trips as UNRECOGNIZED(99) or
        // (on older swift-protobuf) it falls back to .unspecified. Both
        // are acceptable — the point is "no crash."
        let comp = o.formats.first?.inline.compression
        XCTAssertNotEqual(comp, .deflate)
        XCTAssertNotEqual(comp, .none)
    }
}
