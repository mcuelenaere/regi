import Foundation
import zlib

/// Raw RFC 1951 deflate / inflate — no zlib header, no gzip wrapper.
///
/// Why: the agent ↔ client protocol's `COMPRESSION_DEFLATE` is defined
/// as raw deflate (matching browsers' `DecompressionStream("deflate-raw")`
/// and Rust's `flate2::write::DeflateEncoder` defaults). The selection is
/// made by passing a negative `windowBits` to libz (-15 = max window
/// size, raw output).
///
/// libz is a system library on macOS; no external dependency needed.
public enum RawDeflate {
    public enum Error: Swift.Error, Equatable {
        case streamInitFailed(Int32)
        case deflateFailed(Int32)
        case inflateFailed(Int32)
    }

    /// Compress `data` with raw deflate, default compression level.
    public static func compress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initRet = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -15,             // negative windowBits → raw deflate
            8,               // memLevel default
            Z_DEFAULT_STRATEGY,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initRet == Z_OK else { throw Error.streamInitFailed(initRet) }
        defer { _ = deflateEnd(&stream) }
        return try runZStream(
            stream: &stream,
            input: data,
            run: { deflate($0, Z_FINISH) },
            errorBuilder: Error.deflateFailed
        )
    }

    /// Inverse of `compress`. Expects raw RFC 1951 input (no zlib /
    /// gzip wrapper).
    public static func decompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initRet = inflateInit2_(
            &stream,
            -15,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initRet == Z_OK else { throw Error.streamInitFailed(initRet) }
        defer { _ = inflateEnd(&stream) }
        return try runZStream(
            stream: &stream,
            input: data,
            run: { inflate($0, Z_FINISH) },
            errorBuilder: Error.inflateFailed
        )
    }

    /// Common output-buffer-grow loop used by both compress and
    /// decompress. `run` invokes libz's `deflate(...)` or `inflate(...)`
    /// with the right finish flag and returns the status code; the
    /// helper feeds it a chunked output buffer and appends produced
    /// bytes until the operation reports `Z_STREAM_END`.
    private static func runZStream(
        stream: inout z_stream,
        input: Data,
        run: (UnsafeMutablePointer<z_stream>) -> Int32,
        errorBuilder: (Int32) -> Error
    ) throws -> Data {
        // libz takes a writable `next_in` pointer even though it doesn't
        // mutate the input bytes. Copy into a mutable buffer so we don't
        // launder `Data`'s value semantics.
        var inputCopy = input
        let chunkSize = 16 * 1024
        var output = Data()

        let result: Result<Data, Error> = inputCopy.withUnsafeMutableBytes { rawIn in
            let inBase = rawIn.bindMemory(to: Bytef.self).baseAddress
            stream.next_in = inBase
            stream.avail_in = UInt32(rawIn.count)

            var chunk = Data(count: chunkSize)
            while true {
                let stepResult: (Int32, Int)? = chunk.withUnsafeMutableBytes { rawOut in
                    guard let outBase = rawOut.bindMemory(to: Bytef.self).baseAddress else {
                        return nil
                    }
                    stream.next_out = outBase
                    stream.avail_out = UInt32(rawOut.count)
                    let status = run(&stream)
                    let produced = rawOut.count - Int(stream.avail_out)
                    return (status, produced)
                }
                guard let (status, produced) = stepResult else {
                    // chunk had zero count — bug, treat as failure
                    return .failure(errorBuilder(Z_BUF_ERROR))
                }
                if produced > 0 {
                    output.append(chunk.prefix(produced))
                }
                if status == Z_STREAM_END {
                    return .success(output)
                }
                if status != Z_OK && status != Z_BUF_ERROR {
                    return .failure(errorBuilder(status))
                }
                // Z_OK or Z_BUF_ERROR with not-yet-end: loop, give it a
                // fresh output chunk.
            }
        }
        switch result {
        case .success(let d): return d
        case .failure(let e): throw e
        }
    }
}
