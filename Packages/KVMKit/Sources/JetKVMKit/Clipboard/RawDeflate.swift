import Foundation

/// One-shot raw RFC 1951 deflate / inflate — no zlib header, no gzip wrapper.
///
/// Why: the agent ↔ client protocol's `COMPRESSION_DEFLATE` is defined
/// as raw deflate (matching browsers' `DecompressionStream("deflate-raw")`
/// and Rust's `flate2::write::DeflateEncoder` defaults).
///
/// Thin wrapper over `RawDeflateStream`, which owns the libz plumbing: a
/// whole-payload call is just one `push` and a `finish`. That also means
/// `decompress` inherits the stream's end-of-data checks, so a short payload
/// throws `.truncated` instead of looping (which is what a hand-rolled
/// `Z_FINISH` loop does when input runs out before the stream ends).
public enum RawDeflate {
    public typealias Error = RawDeflateStream.Error

    /// Compress `data` with raw deflate, default compression level.
    public static func compress(_ data: Data) throws -> Data {
        try run(data, mode: .compress)
    }

    /// Inverse of `compress`. Expects raw RFC 1951 input (no zlib /
    /// gzip wrapper); throws on a truncated or corrupt stream.
    public static func decompress(_ data: Data) throws -> Data {
        try run(data, mode: .decompress)
    }

    private static func run(_ data: Data, mode: RawDeflateStream.Mode) throws -> Data {
        let stream = try RawDeflateStream(mode: mode)
        var out = try stream.push(data)
        out.append(try stream.finish())
        return out
    }
}
