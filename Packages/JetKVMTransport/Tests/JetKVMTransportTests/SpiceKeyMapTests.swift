import XCTest
@testable import JetKVMTransport

final class SpiceKeyMapTests: XCTestCase {

    func testCommonLettersAndDigits() {
        // kVK_ANSI_A (0x00) → Set-1 0x1E; kVK_ANSI_1 (0x12) → 0x02.
        XCTAssertEqual(SpiceKeyMap.scancode(forVirtualKeyCode: 0x00), SpiceScancode(code: 0x1E, extended: false))
        XCTAssertEqual(SpiceKeyMap.scancode(forVirtualKeyCode: 0x12), SpiceScancode(code: 0x02, extended: false))
        XCTAssertEqual(SpiceKeyMap.scancode(forVirtualKeyCode: 0x24), SpiceScancode(code: 0x1C, extended: false)) // Return
    }

    func testExtendedKeysAndWireEncoding() {
        // Left arrow (0x7B) → extended 0x4B → wire 0xe0 | (0x4b<<8) = 0x4be0.
        let left = try! XCTUnwrap(SpiceKeyMap.scancode(forVirtualKeyCode: 0x7B))
        XCTAssertTrue(left.extended)
        XCTAssertEqual(left.code, 0x4B)
        XCTAssertEqual(left.wireCode, 0x4be0)

        // Right control (0x3E) → extended 0x1D → wire 0x1de0.
        let rctrl = try! XCTUnwrap(SpiceKeyMap.scancode(forVirtualKeyCode: 0x3E))
        XCTAssertEqual(rctrl.wireCode, 0x1de0)
    }

    func testNormalWireEncodingIsRaw() {
        let a = SpiceScancode(code: 0x1E, extended: false)
        XCTAssertEqual(a.wireCode, 0x1E)
    }

    func testUnknownKeyReturnsNil() {
        XCTAssertNil(SpiceKeyMap.scancode(forVirtualKeyCode: 0xFFFF))
    }

    func testNoDuplicateScancodeCollisionsForLetters() {
        // Sanity: the 26 letter vks map to 26 distinct make codes.
        let letterVKs: [UInt16] = [0x00,0x0B,0x08,0x02,0x0E,0x03,0x05,0x04,0x22,0x26,
                                   0x28,0x25,0x2E,0x2D,0x1F,0x23,0x0C,0x0F,0x01,0x11,
                                   0x20,0x09,0x0D,0x07,0x10,0x06]
        let codes = Set(letterVKs.compactMap { SpiceKeyMap.scancode(forVirtualKeyCode: $0)?.code })
        XCTAssertEqual(codes.count, 26)
    }
}
