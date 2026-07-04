import XCTest
@testable import JetKVMTransport

final class VNCWireTests: XCTestCase {
    func testWriterBigEndian() {
        var w = VNCByteWriter()
        w.writeU8(0x01)
        w.writeU16(0x0203)
        w.writeU32(0x0405_0607)
        w.writeS32(-2)
        XCTAssertEqual([UInt8](w.data),
                       [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0xFF, 0xFF, 0xFF, 0xFE])
    }

    func testReaderRoundTrip() throws {
        var w = VNCByteWriter()
        w.writeU8(200)
        w.writeU16(40000)
        w.writeU32(3_000_000_000)
        w.writeS32(-123456)
        w.writeBytes([9, 8, 7])
        var r = VNCByteReader(w.data)
        XCTAssertEqual(try r.readU8(), 200)
        XCTAssertEqual(try r.readU16(), 40000)
        XCTAssertEqual(try r.readU32(), 3_000_000_000)
        XCTAssertEqual(try r.readS32(), -123456)
        XCTAssertEqual(try r.readBytes(3), [9, 8, 7])
        XCTAssertEqual(r.remaining, 0)
    }

    func testReaderUnderrunThrows() {
        var r = VNCByteReader(Data([0x01, 0x02]))
        XCTAssertThrowsError(try r.readU32())
    }

    func testReaderNormalizesSliceStartIndex() throws {
        // A Data slice whose startIndex != 0 (as Network.framework hands out).
        let full = Data([0xAA, 0xBB, 0x12, 0x34, 0x56])
        let slice = full.suffix(from: 2) // startIndex == 2
        var r = VNCByteReader(slice)
        XCTAssertEqual(try r.readU8(), 0x12)
        XCTAssertEqual(try r.readU16(), 0x3456)
    }
}
