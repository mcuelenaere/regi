import Foundation
import ProbeKit

/// Stable ASCII names for keys, so a scenario says `"leftShift"` rather than
/// `0x38`.
///
/// Scenarios are meant to be written by hand or generated, and a raw virtual
/// keycode is both unreadable and easy to get wrong by one. The display labels
/// in `KeyLabels` are for humans reading output ("⇧L"); these are for authoring.
public enum KeyNames {
    public static let byName: [String: UInt16] = {
        var m: [String: UInt16] = [
            "leftShift": 0x38, "rightShift": 0x3C,
            "leftControl": 0x3B, "rightControl": 0x3E,
            "leftOption": 0x3A, "rightOption": 0x3D,
            "leftCommand": 0x37, "rightCommand": 0x36,
            "capsLock": 0x39,
            "return": 0x24, "tab": 0x30, "space": 0x31,
            "delete": 0x33, "escape": 0x35,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
            "minus": 0x1B, "equals": 0x18, "leftBracket": 0x21, "rightBracket": 0x1E,
            "backslash": 0x2A, "semicolon": 0x29, "quote": 0x27,
            "comma": 0x2B, "period": 0x2F, "slash": 0x2C, "backtick": 0x32,
        ]
        // Letters and digits keep their obvious names.
        for (kvk, label) in KeyLabels.named where label.count == 1 {
            let lower = label.lowercased()
            if m[lower] == nil, lower.rangeOfCharacter(from: .alphanumerics) != nil {
                m[lower] = kvk
            }
        }
        for i in 1...12 { if let kvk = KeyLabels.named.first(where: { $0.value == "F\(i)" })?.key {
            m["f\(i)"] = kvk
        } }
        return m
    }()

    public static let byKeyCode: [UInt16: String] = {
        var m: [UInt16: String] = [:]
        // Deterministic: prefer the shortest name, then alphabetical, so the
        // same keycode always round-trips to the same string.
        for (name, kvk) in byName.sorted(by: { ($0.key.count, $0.key) < ($1.key.count, $1.key) })
        where m[kvk] == nil {
            m[kvk] = name
        }
        return m
    }()

    public static func keyCode(_ name: String) throws -> UInt16 {
        guard let kvk = byName[name.lowercased()] ?? byName[name] else {
            throw ScenarioFormatError.unknownKey(name)
        }
        return kvk
    }

    public static func name(_ kvk: UInt16) -> String {
        byKeyCode[kvk] ?? "kvk:\(kvk)"
    }
}

public enum ScenarioFormatError: Error, CustomStringConvertible {
    case unknownKey(String)
    case unknownStep(String)
    case unknownExpectation(String)
    case missingField(String, in: String)

    public var description: String {
        switch self {
        case .unknownKey(let n):
            return "unknown key \"\(n)\" — see `regi-e2e schema` for the list"
        case .unknownStep(let n):
            return "unknown step \"\(n)\" — see `regi-e2e schema`"
        case .unknownExpectation(let n):
            return "unknown expectation \"\(n)\" — see `regi-e2e schema`"
        case .missingField(let f, let ctx):
            return "\"\(ctx)\" needs a \"\(f)\" field"
        }
    }
}
