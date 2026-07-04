import XCTest
@testable import PiKVMKit
import JetKVMKit

/// Sanity tests on the generated `WebKeyMap.virtualKeyToWebCode`.
/// If these break, re-run `Tools/keymap-codegen/main.swift --webkeymap …`.
final class WebKeyMapTests: XCTestCase {
    func testCanonicalMappings() {
        let cases: [(UInt16, String)] = [
            (0x00, "KeyA"),
            (0x0E, "KeyE"),
            (0x11, "KeyT"),
            (0x12, "Digit1"),
            (0x1D, "Digit0"),
            (0x24, "Enter"),
            (0x30, "Tab"),
            (0x31, "Space"),
            (0x33, "Backspace"),
            (0x35, "Escape"),
            (0x37, "MetaLeft"),
            (0x38, "ShiftLeft"),
            (0x39, "CapsLock"),
            (0x3A, "AltLeft"),
            (0x3B, "ControlLeft"),
            (0x7B, "ArrowLeft"),
            (0x7E, "ArrowUp"),
            (0x7A, "F1"),
            (0x6F, "F12"),
        ]
        for (kvk, expected) in cases {
            XCTAssertEqual(WebKeyMap.virtualKeyToWebCode[kvk], expected, "kVK 0x\(String(kvk, radix: 16))")
        }
    }

    /// WebKeyMap and KeyMap derive from the same `kVKToCode` table, so
    /// every USB-HID key must have a matching W3C-code entry.
    func testCoversSameKeysAsHIDMap() {
        XCTAssertEqual(
            Set(WebKeyMap.virtualKeyToWebCode.keys),
            Set(KeyMap.virtualKeyToHIDUsageID.keys),
            "WebKeyMap and KeyMap should cover the same kVK keys"
        )
    }

    func testTableSizeIsSensible() {
        let count = WebKeyMap.virtualKeyToWebCode.count
        XCTAssertGreaterThan(count, 80)
        XCTAssertLessThan(count, 130)
    }
}
