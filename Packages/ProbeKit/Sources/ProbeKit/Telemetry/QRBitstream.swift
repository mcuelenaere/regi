import Foundation

/// `VNBarcodeObservation.payloadData` returns the raw QR **bit stream** — the
/// 4-bit mode indicator and the character-count header still attached — not the
/// decoded payload. On a version-40 byte-mode symbol the real bytes start at
/// bit 20, i.e. nibble-misaligned.
///
/// This matters more than it looks: a naive read reports a 100% decode rate and
/// hands back garbage. Measured during the step 0 spike, where it presented as
/// "every frame decodes, every frame fails verification".
public enum QRBitstream {
    public static func bytePayload(from raw: Data) -> Data? {
        var reader = BitReader(raw)
        for _ in 0..<4 {
            guard let mode = reader.read(4) else { return nil }
            switch mode {
            case 0b0100: // byte mode
                // 16-bit count for versions 10-40, 8-bit for 1-9. Telemetry is
                // always a large symbol, so the wide form is the real case; the
                // narrow one is a clean fallback since an over-long length
                // simply runs past the end of the data.
                for countBits in [16, 8] {
                    var probe = reader
                    guard let n = probe.read(countBits), n > 0,
                          let out = probe.readBytes(Int(n)) else { continue }
                    return out
                }
                return nil
            case 0b0111: // ECI — skip the assignment number, then re-read the mode
                guard let first = reader.read(8) else { return nil }
                if first & 0x80 == 0 { continue }
                if first & 0xC0 == 0x80 { _ = reader.read(8) } else { _ = reader.read(16) }
            default:
                return nil
            }
        }
        return nil
    }

    struct BitReader {
        private let bytes: [UInt8]
        private var bit = 0
        init(_ data: Data) { bytes = [UInt8](data) }

        mutating func read(_ count: Int) -> UInt32? {
            guard count <= 32, bit + count <= bytes.count * 8 else { return nil }
            var v: UInt32 = 0
            for _ in 0..<count {
                v = (v << 1) | UInt32((bytes[bit >> 3] >> (7 - UInt8(bit & 7))) & 1)
                bit += 1
            }
            return v
        }

        mutating func readBytes(_ count: Int) -> Data? {
            guard bit + count * 8 <= bytes.count * 8 else { return nil }
            var out = [UInt8](); out.reserveCapacity(count)
            for _ in 0..<count {
                guard let b = read(8) else { return nil }
                out.append(UInt8(b))
            }
            return Data(out)
        }
    }
}
