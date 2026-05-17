import XCTest
@testable import JetKVMProtocol

final class RawDeflateTests: XCTestCase {

    func testRoundTripEmpty() throws {
        let original = Data()
        let compressed = try RawDeflate.compress(original)
        let restored = try RawDeflate.decompress(compressed)
        XCTAssertEqual(restored, original)
    }

    func testRoundTripShortText() throws {
        let original = Data("hello world, this is a short payload.".utf8)
        let compressed = try RawDeflate.compress(original)
        let restored = try RawDeflate.decompress(compressed)
        XCTAssertEqual(restored, original)
    }

    func testRoundTrip64KiBRandom() throws {
        // Random bytes don't compress well — exercises the output-buffer
        // grow loop in `runZStream` since the deflate output approaches
        // the input size.
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(64 * 1024)
        for _ in 0..<(64 * 1024) {
            bytes.append(UInt8.random(in: 0...255, using: &rng))
        }
        let original = Data(bytes)
        let compressed = try RawDeflate.compress(original)
        let restored = try RawDeflate.decompress(compressed)
        XCTAssertEqual(restored, original)
    }

    /// Reference vector cross-checked against:
    ///   python3 -c "import zlib; co=zlib.compressobj(-1, zlib.DEFLATED, -15);
    ///               print((co.compress(b'hello world')+co.flush()).hex())"
    /// → "cb48cdc9c95728cf2fca490100"
    ///
    /// This catches any future regression in raw-deflate framing
    /// (e.g. accidentally producing a zlib-wrapped output).
    func testDecompressKnownGoodVector() throws {
        let compressed = Data([
            0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf,
            0x2f, 0xca, 0x49, 0x01, 0x00,
        ])
        let restored = try RawDeflate.decompress(compressed)
        XCTAssertEqual(restored, Data("hello world".utf8))
    }

    func testCompressIsRaw_NotZlibWrapped() throws {
        // A zlib-wrapped stream starts with a 2-byte header whose first
        // byte's low nibble = 8 (deflate method) and a checksum trailer.
        // Raw deflate has neither. Sanity-check that our output isn't
        // zlib-shaped: the first byte of "hello world" raw-deflated is
        // 0xcb, not 0x78 (the common zlib first byte for default level).
        let compressed = try RawDeflate.compress(Data("hello world".utf8))
        XCTAssertEqual(compressed.first, 0xcb)
    }

    func testDecompressMalformedThrows() {
        // Truncated stream — inflate should fail with Z_DATA_ERROR.
        let bogus = Data([0xff, 0xff, 0xff])
        XCTAssertThrowsError(try RawDeflate.decompress(bogus)) { error in
            guard let e = error as? RawDeflate.Error else {
                return XCTFail("unexpected error type: \(error)")
            }
            switch e {
            case .inflateFailed: break  // expected
            default: XCTFail("expected .inflateFailed, got \(e)")
            }
        }
    }
}
