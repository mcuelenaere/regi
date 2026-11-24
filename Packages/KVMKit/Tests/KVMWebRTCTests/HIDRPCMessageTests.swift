// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import KVMWebRTC

/// Wire-format fixtures for the HID-RPC messages Regi sends.
///
/// Each `testEncode*` test asserts the exact byte layout the server
/// expects, so a change to the encoder that moves a byte fails here.
final class HIDRPCMessageTests: XCTestCase {

    // MARK: - Handshake (0x01)

    func testEncodeHandshake() {
        let msg = HIDRPCMessage.handshake(version: 0x01)
        XCTAssertEqual(msg.wireFormat, Data([0x01, 0x01]))
    }

    func testStandardHandshakeMatchesProtocolVersion() {
        XCTAssertEqual(HIDRPCMessage.standardHandshake.wireFormat, Data([0x01, 0x01]))
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

    // MARK: - KeypressKeepAliveReport (0x09) — no payload

    func testEncodeKeepAlive() {
        XCTAssertEqual(HIDRPCMessage.keypressKeepAliveReport.wireFormat, Data([0x09]))
    }
}
