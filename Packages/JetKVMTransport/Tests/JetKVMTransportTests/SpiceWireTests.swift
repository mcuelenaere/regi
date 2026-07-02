import XCTest
@testable import JetKVMTransport

final class SpiceWireTests: XCTestCase {

    func testReaderWriterRoundTrip() throws {
        var w = SpiceByteWriter()
        w.writeU8(0xAB)
        w.writeU16(0x1234)
        w.writeU32(0xDEADBEEF)
        w.writeU64(0x0102030405060708)
        w.writeI16(-2)
        w.writeBytes([0x10, 0x20, 0x30])

        var r = SpiceByteReader(w.data)
        XCTAssertEqual(try r.readU8(), 0xAB)
        XCTAssertEqual(try r.readU16(), 0x1234)
        XCTAssertEqual(try r.readU32(), 0xDEADBEEF)
        XCTAssertEqual(try r.readU64(), 0x0102030405060708)
        XCTAssertEqual(try r.readI16(), -2)
        XCTAssertEqual(try r.readBytes(3), [0x10, 0x20, 0x30])
        XCTAssertTrue(r.isAtEnd)
    }

    func testLittleEndianByteOrder() {
        var w = SpiceByteWriter()
        w.writeU32(0x11223344)
        XCTAssertEqual([UInt8](w.data), [0x44, 0x33, 0x22, 0x11])
    }

    func testReaderThrowsOnShortRead() {
        var r = SpiceByteReader([0x01, 0x02])
        XCTAssertThrowsError(try r.readU32()) { err in
            XCTAssertEqual(err as? SpiceByteReader.Error,
                           .outOfBounds(needed: 4, remaining: 2))
        }
    }

    func testCapsBitsRoundTrip() {
        let caps = SpiceCaps(bits: [
            SpiceProtocol.CommonCap.authSpice.rawValue,
            SpiceProtocol.CommonCap.miniHeader.rawValue,
        ])
        XCTAssertTrue(caps.has(SpiceProtocol.CommonCap.authSpice.rawValue))
        XCTAssertTrue(caps.has(SpiceProtocol.CommonCap.miniHeader.rawValue))
        XCTAssertFalse(caps.has(SpiceProtocol.CommonCap.authSasl.rawValue))
        XCTAssertEqual(caps.wordCount, 1)
        // bits 1 and 3 set -> 0b1010 = 0x0A
        XCTAssertEqual(caps.words, [0x0A])
    }
}
