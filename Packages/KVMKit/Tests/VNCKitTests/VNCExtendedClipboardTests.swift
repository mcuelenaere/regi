import XCTest
@testable import VNCKit

final class VNCExtendedClipboardTests: XCTestCase {
    func testParseCaps() throws {
        // caps + text, with one u32 max-size for text.
        var w = VNCByteWriter()
        let flags = VNCExtendedClipboard.Flags([.caps, .text])
        w.writeU32(flags.rawValue)
        w.writeU32(4096)
        let msg = try VNCExtendedClipboard.parse(w.data)
        guard case .caps(_, let maxSize) = msg else { return XCTFail("expected caps") }
        XCTAssertEqual(maxSize, 4096)
    }

    func testParseRequestPeekNotify() throws {
        var req = VNCByteWriter(); req.writeU32(VNCExtendedClipboard.Flags([.request, .text]).rawValue)
        if case .request(let f) = try VNCExtendedClipboard.parse(req.data) {
            XCTAssertTrue(f.contains(.text))
        } else { XCTFail("expected request") }

        var peek = VNCByteWriter(); peek.writeU32(VNCExtendedClipboard.Flags([.peek]).rawValue)
        XCTAssertEqual(try VNCExtendedClipboard.parse(peek.data), .peek)

        var notify = VNCByteWriter(); notify.writeU32(VNCExtendedClipboard.Flags([.notify, .text]).rawValue)
        if case .notify(let f) = try VNCExtendedClipboard.parse(notify.data) {
            XCTAssertTrue(f.contains(.text))
        } else { XCTFail("expected notify") }
    }

    func testProvideRoundTrip() throws {
        // Encode a provide payload, then parse it back.
        let original = "Hello, 世界\nsecond line"
        let payload = try VNCExtendedClipboard.encodeProvide(text: original)
        let msg = try VNCExtendedClipboard.parse(payload)
        guard case .provide(let text) = msg else { return XCTFail("expected provide") }
        // Line endings normalize to \n on decode.
        XCTAssertEqual(text, original)
    }

    func testTextNormalizationCRLFAndNUL() {
        let encoded = VNCExtendedClipboard.encodeText("a\nb")
        // "a\r\nb\0"
        XCTAssertEqual([UInt8](encoded), [UInt8(ascii: "a"), 0x0D, 0x0A, UInt8(ascii: "b"), 0x00])
        // Round-trip decode strips the NUL and de-CRLFs.
        XCTAssertEqual(VNCExtendedClipboard.decodeText(encoded), "a\nb")
    }

    func testEncodeCapsAdvertisesTextAndActions() throws {
        let caps = VNCExtendedClipboard.encodeCaps(textMaxUnsolicitedSize: 1024)
        let msg = try VNCExtendedClipboard.parse(caps)
        guard case .caps(let actions, let maxSize) = msg else { return XCTFail("expected caps") }
        XCTAssertTrue(actions.contains(.text))
        XCTAssertTrue(actions.contains(.provide))
        XCTAssertTrue(actions.contains(.request))
        XCTAssertEqual(maxSize, 1024)
    }

    func testParseNoActionThrows() {
        var w = VNCByteWriter(); w.writeU32(VNCExtendedClipboard.Flags.text.rawValue) // format bit only
        XCTAssertThrowsError(try VNCExtendedClipboard.parse(w.data))
    }
}
