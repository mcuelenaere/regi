// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import zlib

/// Incremental raw RFC 1951 deflate / inflate.
///
/// `RawDeflate`'s one-shot form needs the whole payload resident twice —
/// fine for a clipboard flavor, wrong for a file. A file representation
/// is streamed chunk by chunk in both directions (read 63 KiB, compress,
/// frame; or: receive a frame, inflate, append to a temp file), so the
/// codec has to keep its state across calls.
///
/// Not thread-safe and not `Sendable`: one instance belongs to one
/// stream, which the bridge drives from the main actor.
final class RawDeflateStream {
    enum Mode {
        case compress
        case decompress
    }

    enum Error: Swift.Error, Equatable {
        case streamInitFailed(Int32)
        case deflateFailed(Int32)
        case inflateFailed(Int32)
        /// `finish()` on a decompressor that never reached the end of the
        /// deflate stream — the sender's payload was cut short.
        case truncated
        /// More input arrived after the deflate stream already ended.
        case trailingGarbage
        /// `push()` after `finish()`.
        case alreadyFinished
    }

    /// Output buffer handed to libz per iteration. Sized so a typical
    /// `StreamData` frame's worth of input needs one or two passes.
    private static let outputChunkBytes = 32 * 1024

    private let mode: Mode
    /// Heap-allocated on purpose. zlib's internal state keeps a back-pointer
    /// to the `z_stream` it was initialized against and returns
    /// `Z_STREAM_ERROR` if it ever sees a different address — so the struct
    /// has to stay put for the life of the codec, which a stored property
    /// passed `inout` across calls does not guarantee.
    private let stream: UnsafeMutablePointer<z_stream>
    private var isFinished = false
    private var sawStreamEnd = false

    init(mode: Mode) throws {
        self.mode = mode
        self.stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        let ret: Int32
        switch mode {
        case .compress:
            ret = deflateInit2_(
                stream,
                Z_DEFAULT_COMPRESSION,
                Z_DEFLATED,
                -15,  // negative windowBits → raw deflate, no zlib wrapper
                8,
                Z_DEFAULT_STRATEGY,
                zlibVersion(),
                Int32(MemoryLayout<z_stream>.size)
            )
        case .decompress:
            ret = inflateInit2_(
                stream,
                -15,
                zlibVersion(),
                Int32(MemoryLayout<z_stream>.size)
            )
        }
        guard ret == Z_OK else {
            stream.deinitialize(count: 1)
            stream.deallocate()
            throw Error.streamInitFailed(ret)
        }
    }

    deinit {
        switch mode {
        case .compress: _ = deflateEnd(stream)
        case .decompress: _ = inflateEnd(stream)
        }
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    /// Feed the next slice of input; returns whatever output it produced,
    /// which may be empty (libz buffers).
    func push(_ data: Data) throws -> Data {
        guard !isFinished else { throw Error.alreadyFinished }
        if data.isEmpty { return Data() }
        if sawStreamEnd {
            // A raw deflate stream is self-terminating, so bytes after its
            // end are either corruption or a second stream we never agreed
            // to. Either way the representation is not what was declared.
            throw Error.trailingGarbage
        }
        return try run(input: data, flush: Z_NO_FLUSH)
    }

    /// Flush the codec's tail. Idempotent; after this `push` throws.
    func finish() throws -> Data {
        if isFinished { return Data() }
        isFinished = true
        let tail = sawStreamEnd ? Data() : try run(input: Data(), flush: Z_FINISH)
        if mode == .decompress, !sawStreamEnd { throw Error.truncated }
        return tail
    }

    private func run(input: Data, flush: Int32) throws -> Data {
        // libz wants a writable `next_in` even though it only reads it, so
        // copy into a mutable buffer rather than laundering `Data`'s value
        // semantics.
        var inputCopy = input
        var output = Data()
        let failure: (Int32) -> Error = (mode == .compress) ? Error.deflateFailed : Error.inflateFailed
        let step: (UnsafeMutablePointer<z_stream>) -> Int32 =
            (mode == .compress) ? { deflate($0, flush) } : { inflate($0, flush) }
        let state = stream

        let result: Result<Data, Error> = inputCopy.withUnsafeMutableBytes { rawIn in
            state.pointee.next_in = rawIn.isEmpty ? nil : rawIn.bindMemory(to: Bytef.self).baseAddress
            state.pointee.avail_in = UInt32(rawIn.count)

            var chunk = Data(count: Self.outputChunkBytes)
            while true {
                let outcome: (status: Int32, produced: Int, remaining: UInt32)? =
                    chunk.withUnsafeMutableBytes { rawOut in
                        guard let outBase = rawOut.bindMemory(to: Bytef.self).baseAddress else {
                            return nil
                        }
                        state.pointee.next_out = outBase
                        state.pointee.avail_out = UInt32(rawOut.count)
                        let status = step(state)
                        return (status, rawOut.count - Int(state.pointee.avail_out), state.pointee.avail_out)
                    }
                guard let outcome else { return .failure(failure(Z_BUF_ERROR)) }
                if outcome.produced > 0 {
                    output.append(chunk.prefix(outcome.produced))
                }
                if outcome.status == Z_STREAM_END {
                    sawStreamEnd = true
                    return .success(output)
                }
                if outcome.status != Z_OK && outcome.status != Z_BUF_ERROR {
                    return .failure(failure(outcome.status))
                }
                // libz only stops short of filling the output buffer once it
                // has taken everything it can from this input, so a non-empty
                // `avail_out` is the "nothing more to do right now" signal.
                if outcome.remaining > 0 {
                    return .success(output)
                }
            }
        }

        switch result {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }
}
