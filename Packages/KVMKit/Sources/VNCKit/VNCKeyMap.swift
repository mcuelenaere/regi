import Foundation

/// Key translation for the VNC backend.
///
/// Preferred path: QEMU Extended Key Events carry an XT ("Set 1") scancode,
/// which is layout-independent — the guest applies its own keyboard layout,
/// exactly like a physical keyboard. The table below maps macOS virtual key
/// codes to XT scancodes.
///
/// Fallback path (server didn't ack extended key events): classic KeyEvent
/// with an X11 keysym. Keysyms bake the layout in client-side, so this path
/// assumes US layout for printables — acceptable for a fallback; QEMU (the
/// primary target) always supports the extended path.
enum VNCKeyMap {
    struct Key {
        /// XT scancode in QEMU wire form: extended (0xE0-prefixed) keys are
        /// `0x80 | code`, plain keys are the code itself.
        let xtKeycode: UInt32
        /// X11 keysym for the classic KeyEvent path; 0 when unknown (the
        /// extended path tolerates it, the fallback path drops the key).
        let keysym: UInt32
    }

    /// Look up a key. `shifted` selects the shifted keysym for printables (the
    /// caller tracks the physical shift state); the scancode is unaffected by
    /// shift.
    static func key(forVirtualKeyCode vk: UInt16, shifted: Bool) -> Key? {
        let xt = xtTable[vk]
        let sym = keysym(forVirtualKeyCode: vk, shifted: shifted)
        guard xt != nil || sym != nil else { return nil }
        return Key(xtKeycode: xt.map { $0.wireCode } ?? 0, keysym: sym ?? 0)
    }

    // MARK: - XT scancodes

    struct XTScancode {
        let code: UInt8
        let extended: Bool
        /// QEMU ext-key-event wire encoding (matches noVNC's `getRFBkeycode`):
        /// extended keys fold the 0xE0 prefix into bit 7.
        var wireCode: UInt32 { extended ? (0x80 | UInt32(code)) : UInt32(code) }
    }

    private static func n(_ c: UInt8) -> XTScancode { XTScancode(code: c, extended: false) }
    private static func e(_ c: UInt8) -> XTScancode { XTScancode(code: c, extended: true) }

    /// macOS virtual key code (`NSEvent.keyCode` / `kVK_*`) → PC Set-1 scancode.
    static let xtTable: [UInt16: XTScancode] = [
        // Letters
        0x00: n(0x1E), 0x0B: n(0x30), 0x08: n(0x2E), 0x02: n(0x20), 0x0E: n(0x12),
        0x03: n(0x21), 0x05: n(0x22), 0x04: n(0x23), 0x22: n(0x17), 0x26: n(0x24),
        0x28: n(0x25), 0x25: n(0x26), 0x2E: n(0x32), 0x2D: n(0x31), 0x1F: n(0x18),
        0x23: n(0x19), 0x0C: n(0x10), 0x0F: n(0x13), 0x01: n(0x1F), 0x11: n(0x14),
        0x20: n(0x16), 0x09: n(0x2F), 0x0D: n(0x11), 0x07: n(0x2D), 0x10: n(0x15),
        0x06: n(0x2C),
        // Number row
        0x12: n(0x02), 0x13: n(0x03), 0x14: n(0x04), 0x15: n(0x05), 0x17: n(0x06),
        0x16: n(0x07), 0x1A: n(0x08), 0x1C: n(0x09), 0x19: n(0x0A), 0x1D: n(0x0B),
        // Punctuation
        0x1B: n(0x0C), 0x18: n(0x0D), 0x21: n(0x1A), 0x1E: n(0x1B), 0x2A: n(0x2B),
        0x29: n(0x27), 0x27: n(0x28), 0x32: n(0x29), 0x2B: n(0x33), 0x2F: n(0x34),
        0x2C: n(0x35),
        // Whitespace / control
        0x24: n(0x1C), 0x30: n(0x0F), 0x31: n(0x39), 0x33: n(0x0E), 0x35: n(0x01),
        0x39: n(0x3A),   // caps lock
        // Modifiers
        0x38: n(0x2A),   // left shift
        0x3C: n(0x36),   // right shift
        0x3B: n(0x1D),   // left control
        0x3A: n(0x38),   // left option/alt
        0x37: e(0x5B),   // left command → left GUI
        0x36: e(0x5C),   // right command → right GUI
        0x3D: e(0x38),   // right option → right alt (AltGr)
        0x3E: e(0x1D),   // right control
        // Function keys
        0x7A: n(0x3B), 0x78: n(0x3C), 0x63: n(0x3D), 0x76: n(0x3E), 0x60: n(0x3F),
        0x61: n(0x40), 0x62: n(0x41), 0x64: n(0x42), 0x65: n(0x43), 0x6D: n(0x44),
        0x67: n(0x57), 0x6F: n(0x58),
        // Arrows (extended)
        0x7B: e(0x4B), 0x7C: e(0x4D), 0x7D: e(0x50), 0x7E: e(0x48),
        // Navigation cluster (extended)
        0x73: e(0x47), 0x77: e(0x4F), 0x74: e(0x49), 0x79: e(0x51),
        0x75: e(0x53),   // forward delete
        0x72: e(0x52),   // help/insert
        // Keypad
        0x52: n(0x52), 0x53: n(0x4F), 0x54: n(0x50), 0x55: n(0x51), 0x56: n(0x4B),
        0x57: n(0x4C), 0x58: n(0x4D), 0x59: n(0x47), 0x5B: n(0x48), 0x5C: n(0x49),
        0x41: n(0x53),   // keypad decimal
        0x45: n(0x4E),   // keypad plus
        0x4E: n(0x4A),   // keypad minus
        0x43: n(0x37),   // keypad multiply
        0x4B: e(0x35),   // keypad divide (extended)
        0x4C: e(0x1C),   // keypad enter (extended)
        0x47: n(0x45),   // num lock / clear
    ]

    // MARK: - Keysyms

    static func keysym(forVirtualKeyCode vk: UInt16, shifted: Bool) -> UInt32? {
        if let special = specialKeysyms[vk] { return special }
        guard let pair = usPrintables[vk] else { return nil }
        let scalar = shifted ? pair.1 : pair.0
        return UInt32(scalar.unicodeScalars.first!.value)
    }

    /// Non-printable keysyms (X11 `XK_*` values). Layout-independent.
    private static let specialKeysyms: [UInt16: UInt32] = [
        0x24: 0xFF0D,   // Return
        0x30: 0xFF09,   // Tab
        0x33: 0xFF08,   // BackSpace (macOS Delete)
        0x35: 0xFF1B,   // Escape
        0x39: 0xFFE5,   // Caps_Lock
        0x38: 0xFFE1, 0x3C: 0xFFE2,   // Shift_L/R
        0x3B: 0xFFE3, 0x3E: 0xFFE4,   // Control_L/R
        0x3A: 0xFFE9, 0x3D: 0xFFEA,   // Alt_L/R (option)
        0x37: 0xFFEB, 0x36: 0xFFEC,   // Super_L/R (command)
        0x7A: 0xFFBE, 0x78: 0xFFBF, 0x63: 0xFFC0, 0x76: 0xFFC1,   // F1-F4
        0x60: 0xFFC2, 0x61: 0xFFC3, 0x62: 0xFFC4, 0x64: 0xFFC5,   // F5-F8
        0x65: 0xFFC6, 0x6D: 0xFFC7, 0x67: 0xFFC8, 0x6F: 0xFFC9,   // F9-F12
        0x7B: 0xFF51, 0x7C: 0xFF53, 0x7D: 0xFF54, 0x7E: 0xFF52,   // Left/Right/Down/Up
        0x73: 0xFF50, 0x77: 0xFF57, 0x74: 0xFF55, 0x79: 0xFF56,   // Home/End/PgUp/PgDn
        0x75: 0xFFFF,   // Delete (forward delete)
        0x72: 0xFF63,   // Insert (help)
        0x47: 0xFF7F,   // Num_Lock (clear)
        0x4C: 0xFF8D,   // KP_Enter
        0x45: 0xFFAB, 0x4E: 0xFFAD, 0x43: 0xFFAA, 0x4B: 0xFFAF,   // KP +,-,*,/
        0x41: 0xFFAE,   // KP_Decimal
        0x52: 0xFFB0, 0x53: 0xFFB1, 0x54: 0xFFB2, 0x55: 0xFFB3, 0x56: 0xFFB4,   // KP 0-4
        0x57: 0xFFB5, 0x58: 0xFFB6, 0x59: 0xFFB7, 0x5B: 0xFFB8, 0x5C: 0xFFB9,   // KP 5-9
    ]

    /// US-layout (unshifted, shifted) characters. Latin-1/ASCII keysyms equal
    /// their Unicode scalar value, so a character pair is enough.
    private static let usPrintables: [UInt16: (Character, Character)] = [
        0x00: ("a", "A"), 0x0B: ("b", "B"), 0x08: ("c", "C"), 0x02: ("d", "D"),
        0x0E: ("e", "E"), 0x03: ("f", "F"), 0x05: ("g", "G"), 0x04: ("h", "H"),
        0x22: ("i", "I"), 0x26: ("j", "J"), 0x28: ("k", "K"), 0x25: ("l", "L"),
        0x2E: ("m", "M"), 0x2D: ("n", "N"), 0x1F: ("o", "O"), 0x23: ("p", "P"),
        0x0C: ("q", "Q"), 0x0F: ("r", "R"), 0x01: ("s", "S"), 0x11: ("t", "T"),
        0x20: ("u", "U"), 0x09: ("v", "V"), 0x0D: ("w", "W"), 0x07: ("x", "X"),
        0x10: ("y", "Y"), 0x06: ("z", "Z"),
        0x12: ("1", "!"), 0x13: ("2", "@"), 0x14: ("3", "#"), 0x15: ("4", "$"),
        0x17: ("5", "%"), 0x16: ("6", "^"), 0x1A: ("7", "&"), 0x1C: ("8", "*"),
        0x19: ("9", "("), 0x1D: ("0", ")"),
        0x1B: ("-", "_"), 0x18: ("=", "+"), 0x21: ("[", "{"), 0x1E: ("]", "}"),
        0x2A: ("\\", "|"), 0x29: (";", ":"), 0x27: ("'", "\""), 0x32: ("`", "~"),
        0x2B: (",", "<"), 0x2F: (".", ">"), 0x2C: ("/", "?"),
        0x31: (" ", " "),
    ]
}
