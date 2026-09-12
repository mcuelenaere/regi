import Foundation

/// Display-only. Assertions compare virtual keycodes directly, so this is for
/// the probe's on-screen keyboard and for readable failure messages — there is
/// deliberately no kVK↔HID identity table in this package.
public enum KeyLabels {
    public static func label(_ kvk: UInt16) -> String {
        if let n = named[kvk] { return n }
        return String(format: "kVK 0x%02X", kvk)
    }

    public static let named: [UInt16: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x1F: "O",
        0x20: "U", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x28: "K",
        0x2D: "N", 0x2E: "M",
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
        0x19: "9", 0x1A: "7", 0x1C: "8", 0x1D: "0",
        0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "Delete", 0x35: "Escape",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        // Both sides matter: left/right fidelity is a core assertion.
        0x37: "⌘L", 0x36: "⌘R",
        0x38: "⇧L", 0x3C: "⇧R",
        0x3A: "⌥L", 0x3D: "⌥R",
        0x3B: "⌃L", 0x3E: "⌃R",
        0x39: "CapsLock", 0x3F: "Fn",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    ]

    /// True for the eight modifier keycodes that arrive as `flagsChanged`
    /// rather than key down/up, plus Caps Lock.
    public static func isModifier(_ kvk: UInt16) -> Bool {
        (0x36...0x3E).contains(kvk) || kvk == 0x3F
    }
}
