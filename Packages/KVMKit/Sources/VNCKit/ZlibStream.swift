import Foundation
import zlib

/// A persistent zlib (RFC 1950) inflate stream. Tight encoding maintains up to
/// four of these per connection — the deflate dictionary carries across
/// rectangles, so each rect's data only inflates correctly when fed through the
/// same live stream. Never finalized: Tight streams have no trailer until the
/// server resets them (via the control byte's reset bits).
/// Failures from either zlib entry point in this file.
enum ZlibError: Swift.Error, Equatable {
    case initFailed(Int32)
    case deflateFailed(Int32)
    case inflateFailed(Int32)
    /// Inflating would have exceeded the caller's bound — a decompression bomb.
    case outputLimitExceeded
}

final class ZlibInflateStream {
    typealias Error = ZlibError

    private var stream = z_stream()
    private var initialized = false

    deinit { end() }

    /// Discard all stream state (Tight's per-rect "reset stream" bits). The
    /// next `inflate` starts a fresh zlib stream (header and all).
    func reset() { end() }

    private func end() {
        if initialized {
            inflateEnd(&stream)
            stream = z_stream()
            initialized = false
        }
    }

    /// Inflate `data`, expecting exactly `expectedCount` bytes out (Tight tells
    /// us the uncompressed size up front via geometry). Throws if the stream
    /// errors or doesn't produce exactly the expected byte count.
    func inflate(_ data: Data, expectedCount: Int) throws -> [UInt8] {
        if !initialized {
            let rc = inflateInit2_(&stream, 15, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
            guard rc == Z_OK else { throw Error.initFailed(rc) }
            initialized = true
        }

        var output = [UInt8](repeating: 0, count: expectedCount)
        var produced = 0
        var input = data // mutable copy: libz wants a non-const next_in

        let status: Int32 = input.withUnsafeMutableBytes { rawIn -> Int32 in
            stream.next_in = rawIn.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = UInt32(rawIn.count)
            return output.withUnsafeMutableBytes { rawOut -> Int32 in
                stream.next_out = rawOut.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = UInt32(expectedCount)
                var rc: Int32 = Z_OK
                while stream.avail_in > 0 && stream.avail_out > 0 {
                    rc = zlib.inflate(&stream, Z_SYNC_FLUSH)
                    if rc != Z_OK { break }
                }
                produced = expectedCount - Int(stream.avail_out)
                return rc
            }
        }
        stream.next_in = nil
        stream.next_out = nil

        guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
            throw Error.inflateFailed(status)
        }
        guard produced == expectedCount else {
            throw Error.inflateFailed(Z_DATA_ERROR)
        }
        return output
    }

    /// Inflate all of `data` through the persistent stream, returning every
    /// byte produced. Unlike `inflate(_:expectedCount:)`, the caller doesn't
    /// know the uncompressed size up front — ZRLE/Zlib rects carry a variable
    /// amount, and the server `Z_SYNC_FLUSH`es per rect so all output for this
    /// input is available. Bounded by `limit` against a decompression bomb.
    func inflateAll(_ data: Data, limit: Int) throws -> [UInt8] {
        if !initialized {
            let rc = inflateInit2_(&stream, 15, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
            guard rc == Z_OK else { throw Error.initFailed(rc) }
            initialized = true
        }
        guard !data.isEmpty else { return [] }

        var output = [UInt8]()
        var input = data
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let status: Int32 = input.withUnsafeMutableBytes { rawIn -> Int32 in
            stream.next_in = rawIn.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = UInt32(rawIn.count)
            var rc: Int32 = Z_OK
            while true {
                let produced = chunk.withUnsafeMutableBytes { rawOut -> Int in
                    stream.next_out = rawOut.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = UInt32(rawOut.count)
                    rc = zlib.inflate(&stream, Z_SYNC_FLUSH)
                    return rawOut.count - Int(stream.avail_out)
                }
                if produced > 0 { output.append(contentsOf: chunk.prefix(produced)) }
                if output.count > limit { rc = Z_MEM_ERROR; break }   // → .outputLimitExceeded
                // Done when the input is drained and the last call didn't fill
                // the output buffer (i.e. no more pending output).
                if rc != Z_OK { break }
                if stream.avail_in == 0 && produced < chunk.count { break }
            }
            return rc
        }
        stream.next_in = nil
        stream.next_out = nil
        if status == Z_MEM_ERROR && output.count > limit { throw Error.outputLimitExceeded }
        guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
            throw Error.inflateFailed(status)
        }
        return output
    }
}

/// One-shot zlib (RFC 1950, header + adler32) helpers for the Extended
/// Clipboard pseudo-encoding, whose `provide` payloads are complete zlib
/// streams.
enum ZlibCodec {
    typealias Error = ZlibError

    static func deflate(_ data: Data) throws -> Data {
        var stream = z_stream()
        let rc = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15, 8,
                               Z_DEFAULT_STRATEGY, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { throw Error.initFailed(rc) }
        defer { deflateEnd(&stream) }

        var input = data
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let result: Int32 = input.withUnsafeMutableBytes { rawIn -> Int32 in
            stream.next_in = rawIn.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = UInt32(rawIn.count)
            while true {
                let status: Int32 = chunk.withUnsafeMutableBytes { rawOut in
                    stream.next_out = rawOut.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = UInt32(rawOut.count)
                    let s = zlib.deflate(&stream, Z_FINISH)
                    let produced = rawOut.count - Int(stream.avail_out)
                    if produced > 0 { output.append(contentsOf: rawOut.prefix(produced)) }
                    return s
                }
                if status == Z_STREAM_END { return Z_OK }
                if status != Z_OK && status != Z_BUF_ERROR { return status }
            }
        }
        guard result == Z_OK else { throw Error.deflateFailed(result) }
        return output
    }

    /// Inflate a complete zlib stream, bounding output at `limit` bytes so a
    /// malicious peer can't decompression-bomb us.
    ///
    /// A one-shot is a fresh persistent stream drained once — same
    /// `Z_SYNC_FLUSH` loop, and the same tolerance for an encoder that skipped
    /// the final flush.
    static func inflate(_ data: Data, limit: Int) throws -> Data {
        Data(try ZlibInflateStream().inflateAll(data, limit: limit))
    }
}
