import XCTest
@testable import VNCKit

final class VNCKeyMapTests: XCTestCase {
    func testLetterUnshiftedAndShifted() throws {
        let a = try XCTUnwrap(VNCKeyMap.key(forVirtualKeyCode: 0x00, shifted: false)) // 'a'
        XCTAssertEqual(a.xtKeycode, 0x1E)
        XCTAssertEqual(a.keysym, 0x61) // 'a'
        let A = try XCTUnwrap(VNCKeyMap.key(forVirtualKeyCode: 0x00, shifted: true))
        XCTAssertEqual(A.xtKeycode, 0x1E, "scancode is unaffected by shift")
        XCTAssertEqual(A.keysym, 0x41) // 'A'
    }

    func testNumberRowShifted() throws {
        let one = try XCTUnwrap(VNCKeyMap.key(forVirtualKeyCode: 0x12, shifted: false))
        XCTAssertEqual(one.xtKeycode, 0x02)
        XCTAssertEqual(one.keysym, UInt32(UInt8(ascii: "1")))
        let bang = try XCTUnwrap(VNCKeyMap.key(forVirtualKeyCode: 0x12, shifted: true))
        XCTAssertEqual(bang.keysym, UInt32(UInt8(ascii: "!")))
    }

    func testSpecialKeys() throws {
        let ret = try XCTUnwrap(VNCKeyMap.key(forVirtualKeyCode: 0x24, shifted: false))
        XCTAssertEqual(ret.xtKeycode, 0x1C)
        XCTAssertEqual(ret.keysym, 0xFF0D) // XK_Return
        let esc = try XCTUnwrap(VNCKeyMap.key(forVirtualKeyCode: 0x35, shifted: false))
        XCTAssertEqual(esc.keysym, 0xFF1B)
    }

    func testExtendedKeysFoldPrefixIntoBit7() throws {
        // Left arrow (0x7B) is an extended (0xE0-prefixed) key → wire 0x80|0x4B.
        let left = try XCTUnwrap(VNCKeyMap.key(forVirtualKeyCode: 0x7B, shifted: false))
        XCTAssertEqual(left.xtKeycode, 0x80 | 0x4B)
        XCTAssertEqual(left.keysym, 0xFF51) // XK_Left
        // Left command → left GUI, extended.
        let cmd = try XCTUnwrap(VNCKeyMap.key(forVirtualKeyCode: 0x37, shifted: false))
        XCTAssertEqual(cmd.xtKeycode, 0x80 | 0x5B)
        XCTAssertEqual(cmd.keysym, 0xFFEB) // XK_Super_L
    }

    func testUnknownKeyReturnsNil() {
        XCTAssertNil(VNCKeyMap.key(forVirtualKeyCode: 0x1FF, shifted: false))
    }
}
