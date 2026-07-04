import Foundation
import CommonCrypto

/// Classic VNC Authentication (security type 2): the server sends a 16-byte
/// random challenge; the client DES-ECB encrypts it with a key derived from the
/// password and returns the 16-byte result.
///
/// The historical quirk: the password's bytes are used as the DES key, but each
/// byte's bits are reversed first (VNC predates a settled convention and RealVNC
/// bit-mirrors the key). The password is truncated to 8 bytes, or zero-padded
/// to 8 if shorter.
enum VNCAuth {
    /// DES key: the password's first 8 UTF-8 bytes (zero-padded), each
    /// bit-reversed.
    static func desKey(from password: String) -> [UInt8] {
        var pw = Array(password.utf8.prefix(8))
        while pw.count < 8 { pw.append(0) }
        return pw.map(reverseBits)
    }

    /// Reverse the bit order of a byte (0b1000_0000 ↔ 0b0000_0001).
    static func reverseBits(_ b: UInt8) -> UInt8 {
        var v = b
        var r: UInt8 = 0
        for _ in 0..<8 {
            r = (r << 1) | (v & 1)
            v >>= 1
        }
        return r
    }

    /// The 16-byte challenge-response: DES-ECB encrypt the challenge with the
    /// bit-reversed password key. Returns empty on a crypto failure (treated as
    /// an auth failure upstream).
    static func response(challenge: Data, password: String) -> Data {
        desECBEncrypt(challenge, key: desKey(from: password))
    }

    static func desECBEncrypt(_ data: Data, key: [UInt8]) -> Data {
        var out = Data(count: data.count + kCCBlockSizeDES)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmDES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, key.count,
                        nil,
                        inPtr.baseAddress, data.count,
                        outPtr.baseAddress, outPtr.count,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { return Data() }
        out.removeSubrange(moved..<out.count)
        return out
    }
}
