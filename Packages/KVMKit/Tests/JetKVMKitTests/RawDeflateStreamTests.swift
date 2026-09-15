import XCTest
@testable import JetKVMKit

/// The incremental codec files use. The important property is interop
/// with the one-shot form in both directions: the peer compresses a whole
/// representation as one raw-deflate stream either way, so a chunked
/// encode must inflate one-shot and vice versa.
final class RawDeflateStreamTests: XCTestCase {

    private static func sampleText(_ repeats: Int) -> Data {
        Data(String(repeating: "the quick brown fox jumps over the lazy dog\n", count: repeats).utf8)
    }

    private func pushAll(_ stream: RawDeflateStream, _ input: Data, chunk: Int) throws -> Data {
        var output = Data()
        var offset = 0
        while offset < input.count {
            let end = min(offset + chunk, input.count)
            output.append(try stream.push(input.subdata(in: offset..<end)))
            offset = end
        }
        output.append(try stream.finish())
        return output
    }

    func testChunkedCompressInflatesOneShot() throws {
        let raw = Self.sampleText(500)
        let compressed = try pushAll(RawDeflateStream(mode: .compress), raw, chunk: 1024)
        XCTAssertLessThan(compressed.count, raw.count)
        XCTAssertEqual(try RawDeflate.decompress(compressed), raw)
    }

    func testOneShotCompressInflatesChunked() throws {
        let raw = Self.sampleText(500)
        let compressed = try RawDeflate.compress(raw)
        // Deliberately awkward chunk size: frame boundaries have nothing to
        // do with the codec's internal block boundaries.
        let inflated = try pushAll(RawDeflateStream(mode: .decompress), compressed, chunk: 37)
        XCTAssertEqual(inflated, raw)
    }

    func testRoundTripThroughBothStreams() throws {
        let raw = Data((0..<200_000).map { UInt8($0 % 251) })
        let compressed = try pushAll(RawDeflateStream(mode: .compress), raw, chunk: 63 * 1024)
        let inflated = try pushAll(RawDeflateStream(mode: .decompress), compressed, chunk: 63 * 1024)
        XCTAssertEqual(inflated, raw)
    }

    func testEmptyInputRoundTrips() throws {
        let compressed = try RawDeflateStream(mode: .compress).finish()
        let inflater = try RawDeflateStream(mode: .decompress)
        var out = try inflater.push(compressed)
        out.append(try inflater.finish())
        XCTAssertEqual(out, Data())
    }

    /// A sender that closes COMPLETE mid-stream must not look like a
    /// successful transfer.
    func testTruncatedInputIsRejectedOnFinish() throws {
        let compressed = try RawDeflate.compress(Self.sampleText(500))
        let inflater = try RawDeflateStream(mode: .decompress)
        _ = try inflater.push(compressed.prefix(compressed.count / 2))
        XCTAssertThrowsError(try inflater.finish()) { error in
            XCTAssertEqual(error as? RawDeflateStream.Error, .truncated)
        }
    }

    func testBytesAfterTheStreamEndAreRejected() throws {
        let compressed = try RawDeflate.compress(Data("payload".utf8))
        let inflater = try RawDeflateStream(mode: .decompress)
        _ = try inflater.push(compressed)
        XCTAssertThrowsError(try inflater.push(Data([0xFF, 0xFF]))) { error in
            XCTAssertEqual(error as? RawDeflateStream.Error, .trailingGarbage)
        }
    }

    func testCorruptInputThrowsRatherThanReturningGarbage() throws {
        let inflater = try RawDeflateStream(mode: .decompress)
        XCTAssertThrowsError(try inflater.push(Data(repeating: 0xFF, count: 64)))
    }

    func testFinishIsIdempotent() throws {
        let deflater = try RawDeflateStream(mode: .compress)
        _ = try deflater.push(Data("x".utf8))
        _ = try deflater.finish()
        XCTAssertEqual(try deflater.finish(), Data())
        XCTAssertThrowsError(try deflater.push(Data("y".utf8))) { error in
            XCTAssertEqual(error as? RawDeflateStream.Error, .alreadyFinished)
        }
    }
}
