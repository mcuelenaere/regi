import Foundation
import zlib

/// Integrity check for the telemetry container.
///
/// Not paranoia: LZFSE will happily decode a **truncated** payload back to its
/// full declared length when the missing tail was an end-of-stream marker, so a
/// damaged frame otherwise arrives looking perfectly valid. A QR read that
/// error-correction only partly repaired lands in the same place. The driver
/// must reject those rather than assert over them.
///
/// CRC-32/ISO-HDLC, straight off the system zlib.
enum CRC32 {
    static func compute(_ data: Data) -> UInt32 {
        UInt32(truncatingIfNeeded: data.withUnsafeBytes { buf in
            crc32(0, buf.bindMemory(to: Bytef.self).baseAddress, uInt(buf.count))
        })
    }
}
