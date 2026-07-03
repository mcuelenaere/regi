import XCTest
@testable import KVMWebRTC

/// Wire-format fixtures + round-trip tests for HID-RPC message codec.
///
/// Each `testEncode*` test asserts the exact byte layout the server
/// expects. Each `testRoundTrip*` test exercises encode → decode →
/// equality. Together they catch both shape regressions and codec bugs.
final class HIDRPCMessageTests: XCTestCase {

    // MARK: - Handshake (0x01)

    func testEncodeHandshake() {
        let msg = HIDRPCMessage.handshake(version: 0x01)
        XCTAssertEqual(msg.wireFormat, Data([0x01, 0x01]))
    }

    func testStandardHandshakeMatchesProtocolVersion() {
        XCTAssertEqual(HIDRPCMessage.standardHandshake.wireFormat, Data([0x01, 0x01]))
    }

    func testRoundTripHandshake() throws {
        let original = HIDRPCMessage.handshake(version: 0x01)
        let decoded = try HIDRPCMessage(wireFormat: original.wireFormat)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - KeyboardReport (0x02)

    func testEncodeKeyboardReportEmpty() {
        let msg = HIDRPCMessage.keyboardReport(modifier: 0x08, keys: [])
        XCTAssertEqual(msg.wireFormat, Data([0x02, 0x08]))
    }

    func testEncodeKeyboardReportMaxKeys() {
        // 6 keys, modifier = LeftMeta (0x08) + LeftShift (0x02)
        let msg = HIDRPCMessage.keyboardReport(
            modifier: 0x0A,
            keys: [0x04, 0x05, 0x06, 0x07, 0x08, 0x09]
        )
        XCTAssertEqual(
            msg.wireFormat,
            Data([0x02, 0x0A, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09])
        )
    }

    func testRoundTripKeyboardReport() throws {
        let original = HIDRPCMessage.keyboardReport(modifier: 0x09, keys: [0x04, 0x05])
        let decoded = try HIDRPCMessage(wireFormat: original.wireFormat)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - PointerReport (0x03) — 9-byte payload

    func testEncodePointerReportZero() {
        let msg = HIDRPCMessage.pointerReport(x: 0, y: 0, buttons: 0)
        XCTAssertEqual(
            msg.wireFormat,
            Data([0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        )
    }

    func testEncodePointerReportTopRight() {
        // X = 32767 = 0x00007FFF, Y = 0, Left button pressed
        let msg = HIDRPCMessage.pointerReport(x: 32767, y: 0, buttons: 0x01)
        XCTAssertEqual(
            msg.wireFormat,
            Data([
                0x03,
                0x00, 0x00, 0x7F, 0xFF, // X big-endian
                0x00, 0x00, 0x00, 0x00, // Y big-endian
                0x01                    // buttons
            ])
        )
    }

    func testRoundTripPointerReport() throws {
        let original = HIDRPCMessage.pointerReport(x: 16384, y: 16384, buttons: 0x05)
        let decoded = try HIDRPCMessage(wireFormat: original.wireFormat)
        XCTAssertEqual(decoded, original)
    }

    func testPointerReportTruncatedPayloadFails() {
        // 8-byte payload (one short)
        let bytes = Data([0x03, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try HIDRPCMessage(wireFormat: bytes))
    }

    // MARK: - KeypressReport (0x05) — 2-byte payload

    func testEncodeKeypressReportPress() {
        // KeyA = 0x04, pressed
        let msg = HIDRPCMessage.keypressReport(key: 0x04, pressed: true)
        XCTAssertEqual(msg.wireFormat, Data([0x05, 0x04, 0x01]))
    }

    func testEncodeKeypressReportRelease() {
        let msg = HIDRPCMessage.keypressReport(key: 0x04, pressed: false)
        XCTAssertEqual(msg.wireFormat, Data([0x05, 0x04, 0x00]))
    }

    func testRoundTripKeypressReport() throws {
        let original = HIDRPCMessage.keypressReport(key: 0x28, pressed: true)
        let decoded = try HIDRPCMessage(wireFormat: original.wireFormat)
        XCTAssertEqual(decoded, original)
    }

    func testKeypressReportTruncatedFails() {
        XCTAssertThrowsError(try HIDRPCMessage(wireFormat: Data([0x05, 0x04])))
    }

    // MARK: - WheelReport (0x04) — 2-byte payload, signed int8 deltas

    func testEncodeWheelReportPositiveDeltas() {
        let msg = HIDRPCMessage.wheelReport(deltaY: 3, deltaX: 1)
        XCTAssertEqual(msg.wireFormat, Data([0x04, 0x03, 0x01]))
    }

    func testEncodeWheelReportNegativeDeltas() {
        // -1 + Int8.min two's-complement
        let msg = HIDRPCMessage.wheelReport(deltaY: -1, deltaX: -128)
        XCTAssertEqual(msg.wireFormat, Data([0x04, 0xFF, 0x80]))
    }

    func testRoundTripWheelReportAllSignedRange() throws {
        for dy in [Int8.min, -1, 0, 1, Int8.max] {
            for dx in [Int8.min, -1, 0, 1, Int8.max] {
                let original = HIDRPCMessage.wheelReport(deltaY: dy, deltaX: dx)
                let decoded = try HIDRPCMessage(wireFormat: original.wireFormat)
                XCTAssertEqual(decoded, original, "deltaY=\(dy), deltaX=\(dx)")
            }
        }
    }

    func testWheelReportShortPayloadFails() {
        // Server rejects anything but exactly 2 payload bytes
        // (internal/hidrpc/message.go:209). Match that strictly.
        XCTAssertThrowsError(try HIDRPCMessage(wireFormat: Data([0x04, 0x01])))
        XCTAssertThrowsError(try HIDRPCMessage(wireFormat: Data([0x04, 0x01, 0x02, 0x03])))
    }

    // MARK: - MouseReport (0x06) — 3-byte payload, signed int8 deltas

    func testEncodeMouseReportPositiveDeltas() {
        let msg = HIDRPCMessage.mouseReport(dx: 10, dy: 20, buttons: 0x02)
        XCTAssertEqual(msg.wireFormat, Data([0x06, 0x0A, 0x14, 0x02]))
    }

    func testEncodeMouseReportNegativeDeltas() {
        // dx = -1, dy = -128 (Int8 min); two's-complement encoding
        let msg = HIDRPCMessage.mouseReport(dx: -1, dy: -128, buttons: 0x00)
        XCTAssertEqual(msg.wireFormat, Data([0x06, 0xFF, 0x80, 0x00]))
    }

    func testRoundTripMouseReportAllSignedRange() throws {
        for dx in [Int8.min, -1, 0, 1, Int8.max] {
            for dy in [Int8.min, -1, 0, 1, Int8.max] {
                let original = HIDRPCMessage.mouseReport(dx: dx, dy: dy, buttons: 0x05)
                let decoded = try HIDRPCMessage(wireFormat: original.wireFormat)
                XCTAssertEqual(decoded, original, "dx=\(dx), dy=\(dy)")
            }
        }
    }

    // MARK: - KeyboardMacroReport (0x07) — variable

    func testEncodeKeyboardMacroReportTwoSteps() {
        let step1 = KeyboardMacroStep(
            modifier: 0x02, // LeftShift
            keys: [0x04, 0x00, 0x00, 0x00, 0x00, 0x00], // KeyA
            delayMs: 50
        )
        let step2 = KeyboardMacroStep(
            modifier: 0x00,
            keys: [0x05, 0x00, 0x00, 0x00, 0x00, 0x00], // KeyB
            delayMs: 100
        )
        let msg = HIDRPCMessage.keyboardMacroReport(isPaste: true, steps: [step1, step2])

        var expected = Data()
        expected.append(0x07) // type
        expected.append(0x01) // isPaste
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x02]) // stepCount BE
        // step 1: modifier + 6 keys + 2-byte delay
        expected.append(0x02)
        expected.append(contentsOf: [0x04, 0x00, 0x00, 0x00, 0x00, 0x00])
        expected.append(contentsOf: [0x00, 0x32]) // 50
        // step 2
        expected.append(0x00)
        expected.append(contentsOf: [0x05, 0x00, 0x00, 0x00, 0x00, 0x00])
        expected.append(contentsOf: [0x00, 0x64]) // 100

        XCTAssertEqual(msg.wireFormat, expected)
    }

    func testRoundTripKeyboardMacroReport() throws {
        let steps = [
            KeyboardMacroStep(modifier: 0x02, keys: [0x04, 0, 0, 0, 0, 0], delayMs: 25),
            KeyboardMacroStep(modifier: 0x00, keys: [0x05, 0x06, 0, 0, 0, 0], delayMs: 0),
        ]
        let original = HIDRPCMessage.keyboardMacroReport(isPaste: false, steps: steps)
        let decoded = try HIDRPCMessage(wireFormat: original.wireFormat)
        XCTAssertEqual(decoded, original)
    }

    func testKeyboardMacroReportInvalidLengthFails() {
        // Header says 2 steps but only one step's worth of bytes
        var bytes = Data([0x07, 0x00])
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x02]) // stepCount = 2
        // Single step: 1 + 6 + 2 = 9 bytes
        bytes.append(contentsOf: Array(repeating: 0, count: 9))
        XCTAssertThrowsError(try HIDRPCMessage(wireFormat: bytes))
    }

    // MARK: - CancelKeyboardMacroReport (0x08), KeypressKeepAliveReport (0x09) — no payload

    func testEncodeCancelMacro() {
        XCTAssertEqual(HIDRPCMessage.cancelKeyboardMacroReport.wireFormat, Data([0x08]))
    }

    func testEncodeKeepAlive() {
        XCTAssertEqual(HIDRPCMessage.keypressKeepAliveReport.wireFormat, Data([0x09]))
    }

    func testRoundTripCancelMacro() throws {
        let decoded = try HIDRPCMessage(wireFormat: Data([0x08]))
        XCTAssertEqual(decoded, .cancelKeyboardMacroReport)
    }

    func testRoundTripKeepAlive() throws {
        let decoded = try HIDRPCMessage(wireFormat: Data([0x09]))
        XCTAssertEqual(decoded, .keypressKeepAliveReport)
    }

    // MARK: - Server → client: KeyboardLedState (0x32), KeydownState (0x33), KeyboardMacroState (0x34)

    func testRoundTripKeyboardLedState() throws {
        // CapsLock LED on (bit 1 in standard keyboard LED report = 0x02)
        let original = HIDRPCMessage.keyboardLedState(ledByte: 0x02)
        let decoded = try HIDRPCMessage(wireFormat: original.wireFormat)
        XCTAssertEqual(decoded, original)
    }

    func testRoundTripKeydownState() throws {
        let original = HIDRPCMessage.keydownState(modifier: 0x08, keys: [0x04, 0x05])
        let decoded = try HIDRPCMessage(wireFormat: original.wireFormat)
        XCTAssertEqual(decoded, original)
    }

    func testRoundTripKeyboardMacroState() throws {
        let original = HIDRPCMessage.keyboardMacroState(active: true, isPaste: false)
        XCTAssertEqual(original.wireFormat, Data([0x34, 0x01, 0x00]))
        let decoded = try HIDRPCMessage(wireFormat: original.wireFormat)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Error paths

    func testEmptyDataFails() {
        XCTAssertThrowsError(try HIDRPCMessage(wireFormat: Data())) { error in
            XCTAssertEqual(error as? HIDRPCDecodingError, .empty)
        }
    }

    func testUnknownTypeFails() {
        XCTAssertThrowsError(try HIDRPCMessage(wireFormat: Data([0xAB, 0x00]))) { error in
            XCTAssertEqual(error as? HIDRPCDecodingError, .unknownType(0xAB))
        }
    }

    // MARK: - typeByte sanity

    func testAllTypeBytesAreUniqueAndMatchSpec() {
        // The opcode should match what HIDRPCMessage(wireFormat: ...)
        // produces back. Cycle each variant with a representative
        // payload and verify.
        let sample6Keys: [UInt8] = [0, 0, 0, 0, 0, 0]
        let messages: [(HIDRPCMessage, UInt8)] = [
            (.handshake(version: 0x01), 0x01),
            (.keyboardReport(modifier: 0, keys: []), 0x02),
            (.pointerReport(x: 0, y: 0, buttons: 0), 0x03),
            (.wheelReport(deltaY: 0, deltaX: 0), 0x04),
            (.keypressReport(key: 0, pressed: false), 0x05),
            (.mouseReport(dx: 0, dy: 0, buttons: 0), 0x06),
            (.keyboardMacroReport(
                isPaste: false,
                steps: [KeyboardMacroStep(modifier: 0, keys: sample6Keys, delayMs: 0)]
            ), 0x07),
            (.cancelKeyboardMacroReport, 0x08),
            (.keypressKeepAliveReport, 0x09),
            (.keyboardLedState(ledByte: 0), 0x32),
            (.keydownState(modifier: 0, keys: []), 0x33),
            (.keyboardMacroState(active: false, isPaste: false), 0x34),
        ]
        for (msg, expectedType) in messages {
            XCTAssertEqual(msg.typeByte, expectedType)
            XCTAssertEqual(msg.wireFormat.first, expectedType)
        }
    }
}
