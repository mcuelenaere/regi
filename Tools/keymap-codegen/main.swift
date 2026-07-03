#!/usr/bin/env swift
// Codegen for `KeyMap.swift` — the macOS-virtual-keycode → USB-HID-Usage-ID
// table used by the keyboard handler.
//
// Inputs:
//   1. The JetKVM TS file `ui/src/keyboardMappings.ts`, which is the
//      authoritative source for (W3C `code` string → USB-HID Usage ID).
//   2. The hand-curated `kVKToCode` table below, which maps macOS Carbon
//      virtual keycodes (`kVK_*` constants from `<Carbon/HIToolbox/Events.h>`)
//      to W3C `code` strings.
//
// Output: a Swift file declaring `KeyMap.virtualKeyToHIDUsageID` keyed by
// `UInt16` (NSEvent.keyCode), printed to stdout.
//
// Run manually when either source changes:
//
//     swift Tools/keymap-codegen/main.swift \
//         /path/to/jetkvm/ui/src/keyboardMappings.ts \
//         > Packages/KVMKit/Sources/JetKVMKit/KeyMap.swift
//
// The WebKeyMap (PiKVM) output lives at
//     Packages/KVMKit/Sources/PiKVMKit/WebKeyMap.swift

import Foundation

// MARK: - kVK_* → W3C code

/// macOS Carbon virtual keycodes (NSEvent.keyCode values) → W3C `code`
/// strings. Reference: <Carbon/HIToolbox/Events.h>, plus the w3c
/// uievents-code spec for the string values.
///
/// Where macOS exposes a key that maps to multiple plausible host keys
/// (e.g. kVK_ANSI_KeypadClear could be NumLock or NumpadClear), we
/// prefer the mapping that's most useful when the host is a PC — that's
/// the realistic JetKVM deployment.
let kVKToCode: [(UInt16, String)] = [
    // Letters
    (0x00, "KeyA"), (0x01, "KeyS"), (0x02, "KeyD"), (0x03, "KeyF"),
    (0x04, "KeyH"), (0x05, "KeyG"), (0x06, "KeyZ"), (0x07, "KeyX"),
    (0x08, "KeyC"), (0x09, "KeyV"), (0x0B, "KeyB"), (0x0C, "KeyQ"),
    (0x0D, "KeyW"), (0x0E, "KeyE"), (0x0F, "KeyR"), (0x10, "KeyY"),
    (0x11, "KeyT"), (0x1F, "KeyO"), (0x20, "KeyU"), (0x22, "KeyI"),
    (0x23, "KeyP"), (0x25, "KeyL"), (0x26, "KeyJ"), (0x28, "KeyK"),
    (0x2D, "KeyN"), (0x2E, "KeyM"),

    // Top-row digits
    (0x12, "Digit1"), (0x13, "Digit2"), (0x14, "Digit3"), (0x15, "Digit4"),
    (0x16, "Digit6"), (0x17, "Digit5"), (0x19, "Digit9"), (0x1A, "Digit7"),
    (0x1C, "Digit8"), (0x1D, "Digit0"),

    // Punctuation
    (0x18, "Equal"), (0x1B, "Minus"), (0x1E, "BracketRight"),
    (0x21, "BracketLeft"), (0x27, "Quote"), (0x29, "Semicolon"),
    (0x2A, "Backslash"), (0x2B, "Comma"), (0x2C, "Slash"),
    (0x2F, "Period"), (0x32, "Backquote"),

    // Whitespace + control
    (0x24, "Enter"), (0x30, "Tab"), (0x31, "Space"),
    (0x33, "Backspace"), (0x35, "Escape"),

    // Modifiers
    (0x37, "MetaLeft"), (0x38, "ShiftLeft"), (0x39, "CapsLock"),
    (0x3A, "AltLeft"), (0x3B, "ControlLeft"),
    (0x36, "MetaRight"), (0x3C, "ShiftRight"), (0x3D, "AltRight"),
    (0x3E, "ControlRight"),

    // Arrows
    (0x7B, "ArrowLeft"), (0x7C, "ArrowRight"),
    (0x7D, "ArrowDown"), (0x7E, "ArrowUp"),

    // Navigation
    (0x72, "Insert"), // kVK_Help — Mac doesn't have Insert, hosts do
    (0x73, "Home"), (0x74, "PageUp"), (0x75, "Delete"),
    (0x77, "End"), (0x79, "PageDown"),

    // Function keys
    (0x7A, "F1"), (0x78, "F2"), (0x63, "F3"), (0x76, "F4"),
    (0x60, "F5"), (0x61, "F6"), (0x62, "F7"), (0x64, "F8"),
    (0x65, "F9"), (0x6D, "F10"), (0x67, "F11"), (0x6F, "F12"),
    (0x69, "F13"), (0x6B, "F14"), (0x71, "F15"), (0x6A, "F16"),
    (0x40, "F17"), (0x4F, "F18"), (0x50, "F19"), (0x5A, "F20"),

    // Numpad
    (0x41, "NumpadDecimal"), (0x43, "NumpadMultiply"),
    (0x45, "NumpadAdd"), (0x47, "NumLock"),
    (0x4B, "NumpadDivide"), (0x4C, "NumpadEnter"),
    (0x4E, "NumpadSubtract"), (0x51, "NumpadEqual"),
    (0x52, "Numpad0"), (0x53, "Numpad1"), (0x54, "Numpad2"),
    (0x55, "Numpad3"), (0x56, "Numpad4"), (0x57, "Numpad5"),
    (0x58, "Numpad6"), (0x59, "Numpad7"), (0x5B, "Numpad8"),
    (0x5C, "Numpad9"),

    // Media (where macOS surfaces them as virtual keys). TS uses
    // older non-`Audio*`-prefixed names.
    (0x48, "VolumeUp"), (0x49, "VolumeDown"), (0x4A, "Mute"),

    // JIS / Japanese keyboard. The TS map covers Yen + NumpadComma;
    // kVK_JIS_Underscore (0x5E), kVK_JIS_Eisu (0x66) and kVK_JIS_Kana
    // (0x68) have no entries in the TS table, so we leave them
    // unmapped — JIS-only macOS users on a non-JIS host get nothing
    // for those three keys, which is the same behaviour as the
    // browser UI.
    (0x5D, "Yen"), (0x5F, "NumpadComma"),
]

// MARK: - Parse TS keyboardMappings.ts

/// Pulls all `Identifier: 0xHEX,` entries out of the TS source. We
/// could also parse the file as JS, but a regex over the export is
/// stable enough — the TS file has been simple key/value literals
/// for years, and the codegen output is committed so any drift is
/// visible in code review.
func parseTSKeyMap(at path: String) throws -> [String: Int] {
    let source = try String(contentsOfFile: path, encoding: .utf8)
    // Limit to the `keys = { … }` block so we don't pick up `modifiers`
    // or `extendedKeys` accidentally.
    guard let keysStart = source.range(of: "export const keys = {"),
          let keysEnd = source.range(of: "} as Record<string, number>;", range: keysStart.upperBound..<source.endIndex)
    else {
        throw NSError(domain: "keymap-codegen", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "couldn't find `export const keys = { ... }` block"
        ])
    }
    let block = String(source[keysStart.upperBound..<keysEnd.lowerBound])
    let pattern = #"([A-Za-z][A-Za-z0-9]*):\s*(0x[0-9a-fA-F]+)"#
    let regex = try NSRegularExpression(pattern: pattern)
    let nsBlock = block as NSString
    var result: [String: Int] = [:]
    regex.enumerateMatches(in: block, range: NSRange(location: 0, length: nsBlock.length)) { match, _, _ in
        guard let match else { return }
        let name = nsBlock.substring(with: match.range(at: 1))
        let hex = nsBlock.substring(with: match.range(at: 2))
        if let value = Int(hex.dropFirst(2), radix: 16) {
            result[name] = value
        }
    }
    return result
}

// MARK: - Compose + emit

func emit(codeToHID: [String: Int]) -> String {
    var lines: [String] = []
    lines.append("// THIS FILE IS GENERATED by Tools/keymap-codegen/main.swift")
    lines.append("// DO NOT EDIT BY HAND. Re-run codegen and commit the result.")
    lines.append("//")
    lines.append("// Source: ui/src/keyboardMappings.ts (W3C code → USB-HID)")
    lines.append("//         + hand-curated kVK_* → W3C code table.")
    lines.append("")
    lines.append("public enum KeyMap {")
    lines.append("    /// macOS Carbon virtual keycode (NSEvent.keyCode) → USB HID Usage ID.")
    lines.append("    /// Use this on `keyDown`/`keyUp` to translate platform events into")
    lines.append("    /// the byte the JetKVM HID gadget expects.")
    lines.append("    public static let virtualKeyToHIDUsageID: [UInt16: UInt8] = [")

    var unmapped: [(UInt16, String)] = []
    let mapped = kVKToCode
        .compactMap { (kvk, code) -> (UInt16, UInt8, String)? in
            guard let hid = codeToHID[code] else {
                unmapped.append((kvk, code))
                return nil
            }
            return (kvk, UInt8(hid), code)
        }
        .sorted { $0.0 < $1.0 }

    for (kvk, hid, code) in mapped {
        let kvkHex = String(format: "0x%02X", kvk)
        let hidHex = String(format: "0x%02X", hid)
        lines.append("        \(kvkHex): \(hidHex), // \(code)")
    }

    lines.append("    ]")
    lines.append("}")
    lines.append("")

    if !unmapped.isEmpty {
        FileHandle.standardError.write(Data(
            ("warning: \(unmapped.count) kVK entries had no corresponding code in TS map:\n"
             + unmapped.map { "  kVK 0x\(String(format: "%02X", $0.0)) → \"\($0.1)\"" }.joined(separator: "\n")
             + "\n").utf8
        ))
    }

    return lines.joined(separator: "\n")
}

// MARK: - Emit WebKeyMap (PiKVM)

/// Render the `kVKToCode` table as `WebKeyMap.virtualKeyToWebCode`.
/// PiKVM's `/api/ws` keyboard events carry the W3C `code` string
/// directly, so — unlike the JetKVM USB-HID table — this needs no TS
/// input; the hand-curated `kVKToCode` above is the whole source.
func emitWebKeyMap() -> String {
    var lines: [String] = []
    lines.append("// THIS FILE IS GENERATED by Tools/keymap-codegen/main.swift")
    lines.append("// DO NOT EDIT BY HAND. Re-run codegen and commit the result.")
    lines.append("//")
    lines.append("// Source: hand-curated kVK_* → W3C `code` table in keymap-codegen")
    lines.append("// (same table that backs KeyMap; PiKVM consumes the `code` strings")
    lines.append("// directly rather than translating them to USB-HID Usage IDs).")
    lines.append("")
    lines.append("public enum WebKeyMap {")
    lines.append("    /// macOS Carbon virtual keycode (NSEvent.keyCode) → W3C")
    lines.append("    /// `KeyboardEvent.code` string. PiKVM's `/api/ws` `key` events")
    lines.append("    /// use these `code` names verbatim as the `key` field.")
    lines.append("    public static let virtualKeyToWebCode: [UInt16: String] = [")
    for (kvk, code) in kVKToCode.sorted(by: { $0.0 < $1.0 }) {
        let kvkHex = String(format: "0x%02X", kvk)
        lines.append("        \(kvkHex): \"\(code)\",")
    }
    lines.append("    ]")
    lines.append("}")
    lines.append("")
    return lines.joined(separator: "\n")
}

// MARK: - main

let args = CommandLine.arguments

// WebKeyMap mode: `--webkeymap <outpath>` emits the PiKVM kVK→W3C-code
// table from `kVKToCode` alone (no TS file needed) and exits.
if let flagIndex = args.firstIndex(of: "--webkeymap") {
    guard flagIndex + 1 < args.count else {
        FileHandle.standardError.write(Data("usage: \(args[0]) --webkeymap <output-path>\n".utf8))
        exit(2)
    }
    let outPath = args[flagIndex + 1]
    do {
        try emitWebKeyMap().write(toFile: outPath, atomically: true, encoding: .utf8)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

guard args.count == 2 else {
    let usage = "usage: \(args[0]) <path-to-keyboardMappings.ts>   # emits KeyMap to stdout\n"
        + "       \(args[0]) --webkeymap <output-path>       # emits WebKeyMap (PiKVM)\n"
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

do {
    let codeToHID = try parseTSKeyMap(at: args[1])
    let output = emit(codeToHID: codeToHID)
    print(output)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
