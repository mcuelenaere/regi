import Compression
import Foundation

/// LZFSE via the system framework — no dependency, symmetric on both ends.
enum Compressor {
    static func compress(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }
        let cap = input.count + 64
        var out = Data(count: cap)
        let n = out.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_LZFSE
                )
            }
        }
        guard n > 0 else { return nil }
        out.removeSubrange(n...)
        return out
    }

    static func decompress(_ input: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var out = Data(count: expectedSize)
        let n = out.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_LZFSE
                )
            }
        }
        guard n == expectedSize else { return nil }
        return out
    }
}
