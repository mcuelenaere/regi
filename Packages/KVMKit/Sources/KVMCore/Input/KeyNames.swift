// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Names for keys, and a US-layout text table, in macOS virtual key codes
/// (`kVK_*` from <Carbon/HIToolbox/Events.h>) — the code space every backend
/// already translates from. For callers that speak in names and characters
/// rather than physical key events, such as an automation client.
///
/// Parsing is lenient about spelling (case, spaces, underscores, common
/// aliases, web `KeyboardEvent.code` names) and strict about meaning: a name
/// it doesn't know is an error, never a guess.
public enum KeyNames {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownKey(String)
        case emptyChord(String)
        case unsupportedCharacters(String)

        public var description: String {
            switch self {
            case .unknownKey(let name):
                return "unknown key \"\(name)\". \(KeyNames.accepted)"
            case .emptyChord(let text):
                return "\"\(text)\" is not a key chord. \(KeyNames.accepted)"
            case .unsupportedCharacters(let chars):
                return "not typeable on a US layout: \(chars)"
            }
        }
    }

    /// What `chord` accepts, for error messages.
    public static let accepted = """
        A chord is modifiers then at most one key, joined by + (or -): "enter", "f2", "ctrl+alt+delete", \
        "shift+tab". Keys: a–z, 0–9, f1–f20, enter, esc, tab, space, backspace, delete, insert, home, end, \
        pageup, pagedown, up, down, left, right, capslock, or any printable character ("/", "?"). \
        Modifiers: ctrl, shift, alt (option), cmd (win, meta, super); rctrl, rshift, ralt (altgr), rcmd.
        """

    /// Modifiers held, in order, around an optional final key. A chord made
    /// only of modifiers ("shift") presses and releases them.
    public struct Chord: Equatable, Sendable {
        public let modifiers: [UInt16]
        public let key: UInt16?
    }

    /// One character's key on a US layout and whether it needs Shift.
    public struct Stroke: Equatable, Sendable {
        public let keyCode: UInt16
        public let shift: Bool
    }

    public static let shift: UInt16 = 0x38
    public static let capsLock: UInt16 = 0x39

    /// Parses `"ctrl+alt+delete"`, `"Ctrl-Alt-Del"`, `"f2"`, `"shift+tab"`,
    /// `"cmd"`, `"ctrl+?"`. Any single printable character names its key; a
    /// letter ignores case, a shifted symbol adds Shift.
    public static func chord(_ text: String) throws -> Chord {
        let parts = try split(text)
        var held: [UInt16] = []
        for (index, part) in parts.enumerated() {
            if let modifier = modifiers[normalized(part)] {
                if !held.contains(modifier) { held.append(modifier) }
                continue
            }
            guard index == parts.count - 1, let stroke = stroke(named: part) else {
                throw ParseError.unknownKey(part)
            }
            if stroke.shift, !held.contains(shift) { held.append(shift) }
            return Chord(modifiers: held, key: stroke.keyCode)
        }
        return Chord(modifiers: held, key: nil)
    }

    /// "+" separates; "-" does too when there is no "+". A trailing doubled
    /// separator is the separator's own key: "ctrl++", "ctrl--".
    private static func split(_ text: String) throws -> [String] {
        // Before trimming: " " is the space key.
        if text.count == 1 { return [text] }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ParseError.emptyChord(text) }
        if trimmed.count == 1 { return [trimmed] }
        let separator: Character = trimmed.contains("+") ? "+" : "-"
        var body = Substring(trimmed)
        var tail: [String] = []
        if body.hasSuffix(String(repeating: separator, count: 2)) {
            body = body.dropLast(2)
            tail = [String(separator)]
        }
        let parts = body.split(separator: separator, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) } + tail
        guard !parts.contains("") else { throw ParseError.emptyChord(text) }
        return parts
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0 != " " && $0 != "_" }
    }

    private static func stroke(named name: String) -> Stroke? {
        if name.count == 1, let character = name.first {
            // "C" is the c key, not shift+c: letters name keys.
            if character.isLetter, let stroke = usText[Character(character.lowercased())] { return stroke }
            return usText[character]
        }
        let name = normalized(name)
        if let code = keys[name] { return Stroke(keyCode: code, shift: false) }
        if let character = punctuation[name] { return usText[character] }
        // Web KeyboardEvent.code: "KeyA", "Digit1".
        for prefix in ["key", "digit"] where name.hasPrefix(prefix) && name.count == prefix.count + 1 {
            return usText[name.last!]
        }
        return nil
    }

    /// The strokes that type `text` on a US layout. `\n` is Return and `\t`
    /// is Tab. Throws listing every character it can't type, so nothing is
    /// half-typed.
    // ponytail: US layout only; a host with another layout gets the keys at
    // US positions. Add per-host layout tables if hosts need them.
    public static func strokes(for text: String) throws -> [Stroke] {
        var strokes: [Stroke] = []
        var unsupported: [Character] = []
        for character in text {
            if let stroke = usText[character] {
                strokes.append(stroke)
            } else if !unsupported.contains(character) {
                unsupported.append(character)
            }
        }
        guard unsupported.isEmpty else {
            throw ParseError.unsupportedCharacters(String(unsupported))
        }
        return strokes
    }

    private static let modifiers: [String: UInt16] = [
        "ctrl": 0x3B, "control": 0x3B, "ctl": 0x3B, "controlleft": 0x3B,
        "shift": 0x38, "shiftleft": 0x38,
        "alt": 0x3A, "option": 0x3A, "opt": 0x3A, "altleft": 0x3A,
        "cmd": 0x37, "command": 0x37, "meta": 0x37, "win": 0x37, "windows": 0x37, "super": 0x37,
        "metaleft": 0x37, "osleft": 0x37,
        "rctrl": 0x3E, "rightctrl": 0x3E, "controlright": 0x3E,
        "rshift": 0x3C, "rightshift": 0x3C, "shiftright": 0x3C,
        "ralt": 0x3D, "rightalt": 0x3D, "altgr": 0x3D, "altright": 0x3D, "roption": 0x3D,
        "rcmd": 0x36, "rightcmd": 0x36, "rwin": 0x36, "metaright": 0x36, "osright": 0x36,
    ]

    private static let keys: [String: UInt16] = [
        "enter": 0x24, "return": 0x24, "tab": 0x30, "space": 0x31, "spacebar": 0x31,
        "backspace": 0x33, "bksp": 0x33, "escape": 0x35, "esc": 0x35,
        "delete": 0x75, "del": 0x75, "insert": 0x72, "ins": 0x72,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pgup": 0x74, "pagedown": 0x79, "pgdn": 0x79,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "arrowleft": 0x7B, "arrowright": 0x7C, "arrowdown": 0x7D, "arrowup": 0x7E,
        "capslock": 0x39, "caps": 0x39,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
        "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69,
        "f14": 0x6B, "f15": 0x71, "f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
    ]

    /// Punctuation by name, resolved through the character table so a
    /// shifted one ("plus") brings its Shift.
    private static let punctuation: [String: Character] = [
        "minus": "-", "dash": "-", "hyphen": "-", "equal": "=", "equals": "=", "plus": "+",
        "comma": ",", "period": ".", "dot": ".", "slash": "/", "backslash": "\\",
        "semicolon": ";", "quote": "'", "apostrophe": "'", "grave": "`", "backtick": "`", "backquote": "`",
        "leftbracket": "[", "bracketleft": "[", "rightbracket": "]", "bracketright": "]",
    ]

    /// Unshifted and shifted characters per key, US ANSI layout.
    private static let usText: [Character: Stroke] = {
        let rows: [(UInt16, Character, Character)] = [
            (0x00, "a", "A"), (0x0B, "b", "B"), (0x08, "c", "C"), (0x02, "d", "D"), (0x0E, "e", "E"),
            (0x03, "f", "F"), (0x05, "g", "G"), (0x04, "h", "H"), (0x22, "i", "I"), (0x26, "j", "J"),
            (0x28, "k", "K"), (0x25, "l", "L"), (0x2E, "m", "M"), (0x2D, "n", "N"), (0x1F, "o", "O"),
            (0x23, "p", "P"), (0x0C, "q", "Q"), (0x0F, "r", "R"), (0x01, "s", "S"), (0x11, "t", "T"),
            (0x20, "u", "U"), (0x09, "v", "V"), (0x0D, "w", "W"), (0x07, "x", "X"), (0x10, "y", "Y"),
            (0x06, "z", "Z"),
            (0x12, "1", "!"), (0x13, "2", "@"), (0x14, "3", "#"), (0x15, "4", "$"), (0x17, "5", "%"),
            (0x16, "6", "^"), (0x1A, "7", "&"), (0x1C, "8", "*"), (0x19, "9", "("), (0x1D, "0", ")"),
            (0x1B, "-", "_"), (0x18, "=", "+"), (0x21, "[", "{"), (0x1E, "]", "}"), (0x2A, "\\", "|"),
            (0x29, ";", ":"), (0x27, "'", "\""), (0x2B, ",", "<"), (0x2F, ".", ">"), (0x2C, "/", "?"),
            (0x32, "`", "~"),
        ]
        var table: [Character: Stroke] = [
            " ": Stroke(keyCode: 0x31, shift: false),
            "\n": Stroke(keyCode: 0x24, shift: false),
            "\r\n": Stroke(keyCode: 0x24, shift: false),   // one Character in Swift
            "\t": Stroke(keyCode: 0x30, shift: false),
        ]
        for (code, plain, shifted) in rows {
            table[plain] = Stroke(keyCode: code, shift: false)
            table[shifted] = Stroke(keyCode: code, shift: true)
        }
        return table
    }()
}
