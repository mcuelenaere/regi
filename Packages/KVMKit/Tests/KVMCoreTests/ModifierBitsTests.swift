import XCTest
@testable import KVMCore

final class ModifierBitsTests: XCTestCase {

    // MARK: - JetKVM-specific bit layout

    func testJetKVMSpecificBitOrder() {
        // These are intentionally NOT the standard USB-HID modifier
        // byte values. Document the JetKVM-specific packing so a
        // refactor can't silently flip back to standard layout.
        XCTAssertEqual(ModifierBits.leftControl.rawValue,  0x01)
        XCTAssertEqual(ModifierBits.leftShift.rawValue,    0x02)
        XCTAssertEqual(ModifierBits.leftAlt.rawValue,      0x04)
        XCTAssertEqual(ModifierBits.leftMeta.rawValue,     0x08)
        XCTAssertEqual(ModifierBits.rightControl.rawValue, 0x10)
        XCTAssertEqual(ModifierBits.rightShift.rawValue,   0x20)
        XCTAssertEqual(ModifierBits.rightAlt.rawValue,     0x40)
        XCTAssertEqual(ModifierBits.rightMeta.rawValue,    0x80)
    }

    func testCmdShiftAOnMac() {
        // Cmd+Shift+A keyboard report from a Mac client should produce
        // modifier byte 0x0A (LeftMeta + LeftShift).
        let mods: ModifierBits = [.leftMeta, .leftShift]
        XCTAssertEqual(mods.rawValue, 0x0A)
    }

    func testAllModifiersSetIs0xFF() {
        let all: ModifierBits = [
            .leftControl, .leftShift, .leftAlt, .leftMeta,
            .rightControl, .rightShift, .rightAlt, .rightMeta,
        ]
        XCTAssertEqual(all.rawValue, 0xFF)
    }

    // MARK: - "any" convenience flags

    func testAnyControlMatchesEitherSide() {
        XCTAssertTrue(ModifierBits.leftControl.intersection(.anyControl).rawValue == 0x01)
        XCTAssertTrue(ModifierBits.rightControl.intersection(.anyControl).rawValue == 0x10)
        XCTAssertTrue(ModifierBits.leftShift.intersection(.anyControl).isEmpty)
    }

    func testAnyMetaCoversBothSides() {
        XCTAssertEqual(ModifierBits.anyMeta.rawValue, 0x88)
    }

    // MARK: - OptionSet semantics

    func testInsertAndRemove() {
        var mods = ModifierBits()
        XCTAssertTrue(mods.isEmpty)
        mods.insert(.leftMeta)
        XCTAssertTrue(mods.contains(.leftMeta))
        XCTAssertFalse(mods.contains(.rightMeta))
        mods.remove(.leftMeta)
        XCTAssertFalse(mods.contains(.leftMeta))
    }

    // MARK: - MouseButtons

    func testMouseButtonValues() {
        XCTAssertEqual(MouseButtons.left.rawValue,    0x01)
        XCTAssertEqual(MouseButtons.right.rawValue,   0x02)
        XCTAssertEqual(MouseButtons.middle.rawValue,  0x04)
        XCTAssertEqual(MouseButtons.back.rawValue,    0x08)
        XCTAssertEqual(MouseButtons.forward.rawValue, 0x10)
    }

    func testMouseButtonsCombination() {
        let lr: MouseButtons = [.left, .right]
        XCTAssertEqual(lr.rawValue, 0x03)
    }

    // MARK: - usbHIDUsageID extension

    func testUSBHIDUsageIDForSingleModifiers() {
        // Standard USB HID modifier-key codes 0xE0..0xE7.
        XCTAssertEqual(ModifierBits.leftControl.usbHIDUsageID,  0xE0)
        XCTAssertEqual(ModifierBits.leftShift.usbHIDUsageID,    0xE1)
        XCTAssertEqual(ModifierBits.leftAlt.usbHIDUsageID,      0xE2)
        XCTAssertEqual(ModifierBits.leftMeta.usbHIDUsageID,     0xE3)
        XCTAssertEqual(ModifierBits.rightControl.usbHIDUsageID, 0xE4)
        XCTAssertEqual(ModifierBits.rightShift.usbHIDUsageID,   0xE5)
        XCTAssertEqual(ModifierBits.rightAlt.usbHIDUsageID,     0xE6)
        XCTAssertEqual(ModifierBits.rightMeta.usbHIDUsageID,    0xE7)
    }

    func testUSBHIDUsageIDForEmptyAndMultiBitIsNil() {
        XCTAssertNil(ModifierBits().usbHIDUsageID)
        XCTAssertNil(ModifierBits.anyShift.usbHIDUsageID)
        XCTAssertNil(([.leftMeta, .leftShift] as ModifierBits).usbHIDUsageID)
    }
}
