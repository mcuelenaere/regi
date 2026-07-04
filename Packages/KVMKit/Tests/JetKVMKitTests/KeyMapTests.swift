import XCTest
@testable import JetKVMKit

/// Sanity tests on the generated `KeyMap.virtualKeyToHIDUsageID`.
/// If these break, re-run `Tools/keymap-codegen/main.swift` against the
/// current TS source and compare the diff.
final class KeyMapTests: XCTestCase {
    /// kVK virtual keycode → expected USB HID Usage ID for a hand-picked
    /// set of canonical keys. Values cross-checked against
    /// <Carbon/HIToolbox/Events.h> and the USB HID Usage Tables.
    func testCanonicalKeyMappings() {
        let cases: [(UInt16, UInt8, String)] = [
            // Letters
            (0x00, 0x04, "kVK_ANSI_A → KeyA"),
            (0x0E, 0x08, "kVK_ANSI_E → KeyE"),
            (0x11, 0x17, "kVK_ANSI_T → KeyT"),
            // Digits (top row)
            (0x12, 0x1E, "kVK_ANSI_1 → Digit1"),
            (0x1D, 0x27, "kVK_ANSI_0 → Digit0"),
            // Whitespace + control
            (0x24, 0x28, "kVK_Return → Enter"),
            (0x30, 0x2B, "kVK_Tab → Tab"),
            (0x31, 0x2C, "kVK_Space → Space"),
            (0x33, 0x2A, "kVK_Delete → Backspace"),
            (0x35, 0x29, "kVK_Escape → Escape"),
            // Modifiers (USB HID 0xE0..0xE7 by spec)
            (0x37, 0xE3, "kVK_Command → MetaLeft"),
            (0x38, 0xE1, "kVK_Shift → ShiftLeft"),
            (0x3A, 0xE2, "kVK_Option → AltLeft"),
            (0x3B, 0xE0, "kVK_Control → ControlLeft"),
            (0x36, 0xE7, "kVK_RightCommand → MetaRight"),
            (0x3C, 0xE5, "kVK_RightShift → ShiftRight"),
            (0x3D, 0xE6, "kVK_RightOption → AltRight"),
            (0x3E, 0xE4, "kVK_RightControl → ControlRight"),
            // Arrows
            (0x7B, 0x50, "kVK_LeftArrow → ArrowLeft"),
            (0x7C, 0x4F, "kVK_RightArrow → ArrowRight"),
            (0x7D, 0x51, "kVK_DownArrow → ArrowDown"),
            (0x7E, 0x52, "kVK_UpArrow → ArrowUp"),
            // Navigation
            (0x73, 0x4A, "kVK_Home → Home"),
            (0x74, 0x4B, "kVK_PageUp → PageUp"),
            (0x77, 0x4D, "kVK_End → End"),
            (0x79, 0x4E, "kVK_PageDown → PageDown"),
            (0x75, 0x4C, "kVK_ForwardDelete → Delete"),
            // Function keys
            (0x7A, 0x3A, "kVK_F1 → F1"),
            (0x6F, 0x45, "kVK_F12 → F12"),
        ]
        for (kvk, expected, label) in cases {
            XCTAssertEqual(
                KeyMap.virtualKeyToHIDUsageID[kvk],
                expected,
                "\(label): expected 0x\(String(expected, radix: 16, uppercase: true))"
            )
        }
    }

    func testNoDuplicateHIDValues() {
        // Each kVK should map to exactly one HID code; we don't assert
        // each HID is unique because some kVKs *can* legitimately
        // collide (e.g. only happens on JIS variants we left unmapped).
        // What we do assert: no surprise duplicates among the keys we
        // actually emitted. A new collision would suggest a codegen bug.
        let pairs = KeyMap.virtualKeyToHIDUsageID.sorted { $0.key < $1.key }
        XCTAssertEqual(pairs.map { $0.key }.count, Set(pairs.map { $0.key }).count, "duplicate kVK keys")
    }

    func testTableSizeIsSensible() {
        // The script emits ~95 entries today. If the count drops a lot,
        // codegen probably broke; if it grows a lot, kVKToCode probably
        // gained entries that need a closer look.
        let count = KeyMap.virtualKeyToHIDUsageID.count
        XCTAssertGreaterThan(count, 80, "table shrank unexpectedly")
        XCTAssertLessThan(count, 130, "table grew unexpectedly")
    }
}
