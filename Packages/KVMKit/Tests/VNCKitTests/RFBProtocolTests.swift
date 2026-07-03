import XCTest
@testable import VNCKit

final class RFBProtocolTests: XCTestCase {
    func testPixelFormatRoundTrip() throws {
        var w = VNCByteWriter()
        RFBProtocol.PixelFormat.bgra32.encode(into: &w)
        XCTAssertEqual(w.data.count, RFBProtocol.PixelFormat.byteCount)
        var r = VNCByteReader(w.data)
        let pf = try RFBProtocol.PixelFormat.parse(&r)
        XCTAssertEqual(pf, RFBProtocol.PixelFormat.bgra32)
    }

    func testBGRA32QualifiesForTPixel() {
        XCTAssertTrue(RFBProtocol.PixelFormat.bgra32.tpixelCompact)
        var pf = RFBProtocol.PixelFormat.bgra32
        pf.depth = 16
        XCTAssertFalse(pf.tpixelCompact)
    }

    func testSetPixelFormatBytes() {
        let data = [UInt8](RFBProtocol.setPixelFormat(.bgra32))
        // type(0) + 3 padding + 16-byte pixel format = 20 bytes.
        XCTAssertEqual(data.count, 20)
        XCTAssertEqual(data[0], 0)             // message type
        XCTAssertEqual(Array(data[1...3]), [0, 0, 0])
        XCTAssertEqual(data[4], 32)            // bits-per-pixel
        XCTAssertEqual(data[5], 24)            // depth
        XCTAssertEqual(data[6], 0)             // big-endian flag
        XCTAssertEqual(data[7], 1)             // true-colour flag
        XCTAssertEqual(Array(data[8...9]), [0, 255])   // red-max
        XCTAssertEqual(data[14], 16)           // red-shift
        XCTAssertEqual(data[15], 8)            // green-shift
        XCTAssertEqual(data[16], 0)            // blue-shift
    }

    func testSetEncodingsBytes() {
        let data = [UInt8](RFBProtocol.setEncodings([RFBProtocol.Encoding.tight,
                                                     RFBProtocol.Encoding.raw,
                                                     RFBProtocol.Encoding.desktopSize]))
        XCTAssertEqual(data[0], 2)              // message type
        XCTAssertEqual(data[1], 0)              // padding
        XCTAssertEqual(Array(data[2...3]), [0, 3])  // count
        // tight = 7
        XCTAssertEqual(Array(data[4...7]), [0, 0, 0, 7])
        // raw = 0
        XCTAssertEqual(Array(data[8...11]), [0, 0, 0, 0])
        // desktopSize = -223 = 0xFFFFFF21
        XCTAssertEqual(Array(data[12...15]), [0xFF, 0xFF, 0xFF, 0x21])
    }

    func testFramebufferUpdateRequestBytes() {
        let data = [UInt8](RFBProtocol.framebufferUpdateRequest(
            incremental: true, x: 0, y: 0, width: 640, height: 480))
        XCTAssertEqual(data[0], 3)
        XCTAssertEqual(data[1], 1)              // incremental
        XCTAssertEqual(Array(data[2...3]), [0, 0])
        XCTAssertEqual(Array(data[4...5]), [0, 0])
        XCTAssertEqual(Array(data[6...7]), [0x02, 0x80]) // 640
        XCTAssertEqual(Array(data[8...9]), [0x01, 0xE0]) // 480
    }

    func testKeyEventBytes() {
        let data = [UInt8](RFBProtocol.keyEvent(keysym: 0x0041, down: true)) // 'A'
        XCTAssertEqual(data[0], 4)
        XCTAssertEqual(data[1], 1)
        XCTAssertEqual(Array(data[2...3]), [0, 0])
        XCTAssertEqual(Array(data[4...7]), [0, 0, 0, 0x41])
    }

    func testQEMUExtendedKeyEventBytes() {
        let data = [UInt8](RFBProtocol.qemuExtendedKeyEvent(keysym: 0xFF0D, keycode: 0x1C, down: false))
        XCTAssertEqual(data[0], 255)
        XCTAssertEqual(data[1], 0)               // submessage
        XCTAssertEqual(Array(data[2...3]), [0, 0]) // down = false
        XCTAssertEqual(Array(data[4...7]), [0, 0, 0xFF, 0x0D])
        XCTAssertEqual(Array(data[8...11]), [0, 0, 0, 0x1C])
    }

    func testPointerEventBytes() {
        let data = [UInt8](RFBProtocol.pointerEvent(buttonMask: 0x01, x: 100, y: 200))
        XCTAssertEqual(data[0], 5)
        XCTAssertEqual(data[1], 0x01)
        XCTAssertEqual(Array(data[2...3]), [0, 100])
        XCTAssertEqual(Array(data[4...5]), [0, 200])
    }

    func testClientCutTextLatin1() {
        let data = [UInt8](RFBProtocol.clientCutText(latin1: "Hi"))
        XCTAssertEqual(data[0], 6)
        XCTAssertEqual(Array(data[1...3]), [0, 0, 0])
        XCTAssertEqual(Array(data[4...7]), [0, 0, 0, 2])
        XCTAssertEqual(Array(data[8...9]), [UInt8(ascii: "H"), UInt8(ascii: "i")])
    }

    func testExtendedClipboardEncodingValue() {
        XCTAssertEqual(RFBProtocol.Encoding.extendedClipboard, -1_063_131_698)
    }

    func testXVPEncodingValueAndMessage() {
        XCTAssertEqual(RFBProtocol.Encoding.xvp, -309)
        // Client XVP: type(250), padding, version(1), action.
        let data = [UInt8](RFBProtocol.xvp(action: RFBProtocol.XVP.actionReset))
        XCTAssertEqual(data, [250, 0, 1, 4])
    }

    func testCompressionAndQualityLevels() {
        XCTAssertEqual(RFBProtocol.Encoding.compressionLevel(2), -254)
        XCTAssertEqual(RFBProtocol.Encoding.jpegQuality(8), -24)
    }
}
