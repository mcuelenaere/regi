// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import KVMCore

final class KeyNamesTests: XCTestCase {
    private let ctrl: UInt16 = 0x3B, alt: UInt16 = 0x3A, shift: UInt16 = 0x38, cmd: UInt16 = 0x37

    func testChordsParseModifiersInOrderAroundTheKey() throws {
        XCTAssertEqual(try KeyNames.chord("ctrl+alt+delete"), .init(modifiers: [ctrl, alt], key: 0x75))
        XCTAssertEqual(try KeyNames.chord("Shift+Tab"), .init(modifiers: [shift], key: 0x30))
        XCTAssertEqual(try KeyNames.chord("f2"), .init(modifiers: [], key: 0x78))
        XCTAssertEqual(try KeyNames.chord("cmd+/"), .init(modifiers: [cmd], key: 0x2C))
    }

    func testSpellingIsLenient() throws {
        let ctrlAltDel = KeyNames.Chord(modifiers: [ctrl, alt], key: 0x75)
        XCTAssertEqual(try KeyNames.chord("Ctrl-Alt-Del"), ctrlAltDel)
        XCTAssertEqual(try KeyNames.chord("control + option + Delete"), ctrlAltDel)
        XCTAssertEqual(try KeyNames.chord("ControlLeft+AltLeft+Delete"), ctrlAltDel)
        XCTAssertEqual(try KeyNames.chord("Page_Up"), .init(modifiers: [], key: 0x74))
        XCTAssertEqual(try KeyNames.chord("ArrowUp"), .init(modifiers: [], key: 0x7E))
        XCTAssertEqual(try KeyNames.chord("win+KeyR"), .init(modifiers: [cmd], key: 0x0F))
        XCTAssertEqual(try KeyNames.chord("AltGr"), .init(modifiers: [0x3D], key: nil))
    }

    func testLettersIgnoreCaseAndShiftedSymbolsAddShift() throws {
        XCTAssertEqual(try KeyNames.chord("ctrl+C"), .init(modifiers: [ctrl], key: 0x08))
        XCTAssertEqual(try KeyNames.chord("ctrl+?"), .init(modifiers: [ctrl, shift], key: 0x2C))
        XCTAssertEqual(try KeyNames.chord("shift+?"), .init(modifiers: [shift], key: 0x2C))
        XCTAssertEqual(try KeyNames.chord("plus"), .init(modifiers: [shift], key: 0x18))
    }

    func testSeparatorsAsKeys() throws {
        XCTAssertEqual(try KeyNames.chord("-"), .init(modifiers: [], key: 0x1B))
        XCTAssertEqual(try KeyNames.chord("ctrl--"), .init(modifiers: [ctrl], key: 0x1B))
        XCTAssertEqual(try KeyNames.chord("ctrl++"), .init(modifiers: [ctrl, shift], key: 0x18))
        XCTAssertEqual(try KeyNames.chord("ctrl+-"), .init(modifiers: [ctrl], key: 0x1B))
        XCTAssertEqual(try KeyNames.chord(" "), .init(modifiers: [], key: 0x31))
    }

    func testAModifierOnItsOwnIsAChordWithoutAKey() throws {
        XCTAssertEqual(try KeyNames.chord("shift"), .init(modifiers: [shift], key: nil))
    }

    func testBadChordsSayWhatIsWrong() {
        XCTAssertThrowsError(try KeyNames.chord("ctrl+bogus")) {
            XCTAssertEqual($0 as? KeyNames.ParseError, .unknownKey("bogus"))
            XCTAssertTrue("\($0)".contains("Modifiers:"), "the error lists what is accepted")
        }
        // A key name anywhere but last is not a modifier.
        XCTAssertThrowsError(try KeyNames.chord("a+ctrl")) {
            XCTAssertEqual($0 as? KeyNames.ParseError, .unknownKey("a"))
        }
        XCTAssertThrowsError(try KeyNames.chord("ctrl+")) {
            XCTAssertEqual($0 as? KeyNames.ParseError, .emptyChord("ctrl+"))
        }
        XCTAssertThrowsError(try KeyNames.chord("")) {
            XCTAssertEqual($0 as? KeyNames.ParseError, .emptyChord(""))
        }
        XCTAssertThrowsError(try KeyNames.chord("é"))
    }

    func testTextMapsToUSStrokesWithShift() throws {
        XCTAssertEqual(try KeyNames.strokes(for: "Hi!\n"), [
            KeyNames.Stroke(keyCode: 0x04, shift: true),
            KeyNames.Stroke(keyCode: 0x22, shift: false),
            KeyNames.Stroke(keyCode: 0x12, shift: true),
            KeyNames.Stroke(keyCode: 0x24, shift: false),
        ])
        XCTAssertEqual(try KeyNames.strokes(for: "a\r\nb").map(\.keyCode), [0x00, 0x24, 0x0B])
    }

    func testUntypeableTextIsRejectedWhole() {
        XCTAssertThrowsError(try KeyNames.strokes(for: "café € é")) {
            XCTAssertEqual($0 as? KeyNames.ParseError, .unsupportedCharacters("é€"))
        }
    }
}
