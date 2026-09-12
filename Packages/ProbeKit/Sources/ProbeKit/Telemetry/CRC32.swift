import Foundation

/// Integrity check for the telemetry container.
///
/// Not paranoia: LZFSE will happily decode a **truncated** payload back to its
/// full declared length when the missing tail was an end-of-stream marker, so a
/// damaged frame otherwise arrives looking perfectly valid. A QR read that
/// error-correction only partly repaired lands in the same place. The driver
/// must reject those rather than assert over them.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func compute(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
