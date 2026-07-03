import Foundation

/// Errors surfaced by the VNC transport. `.authFailed` maps to the App layer's
/// password prompt (mirroring the JetKVM/PiKVM flows); the rest surface as
/// `.failed`.
enum VNCConnectionError: Error, Equatable {
    case connectionFailed(String)
    case connectionClosed
    case protocolError(String)
    /// Server rejected the connection during the handshake (no acceptable
    /// security type, or a server reason string). Carries the reason.
    case handshakeFailed(String)
    /// VNC authentication failed, or a password is required and none was
    /// supplied. The App layer prompts for a password on this.
    case authFailed(String)
    case unsupportedVersion(String)
    /// TLS (VeNCrypt) trust evaluation failed and the user hasn't opted into
    /// trusting this host's self-signed certificate. The App layer surfaces the
    /// trust-override prompt.
    case untrustedCertificate(String)
}

/// Big-endian reader over a `Data` (RFB is big-endian on the wire). Normalizes
/// `startIndex` so it works on `Data` slices handed out by Network.framework,
/// and throws `.protocolError` on underrun rather than trapping.
struct VNCByteReader {
    private let data: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    var remaining: Int { data.endIndex - index }

    mutating func readU8() throws -> UInt8 {
        guard index < data.endIndex else {
            throw VNCConnectionError.protocolError("byte-reader underrun")
        }
        defer { index += 1 }
        return data[index]
    }

    mutating func readU16() throws -> UInt16 {
        let b = try readBytes(2)
        return (UInt16(b[0]) << 8) | UInt16(b[1])
    }

    mutating func readU32() throws -> UInt32 {
        let b = try readBytes(4)
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    mutating func readS32() throws -> Int32 { Int32(bitPattern: try readU32()) }

    mutating func readBytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, remaining >= n else {
            throw VNCConnectionError.protocolError("byte-reader underrun: need \(n), have \(remaining)")
        }
        let start = index
        index += n
        return [UInt8](data[start..<index])
    }

    mutating func readData(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else {
            throw VNCConnectionError.protocolError("byte-reader underrun: need \(n), have \(remaining)")
        }
        let start = index
        index += n
        return data.subdata(in: start..<index)
    }
}

/// Big-endian writer producing RFB wire bytes.
struct VNCByteWriter {
    private(set) var data = Data()

    init() {}

    mutating func writeU8(_ v: UInt8) { data.append(v) }

    mutating func writeU16(_ v: UInt16) {
        data.append(UInt8(truncatingIfNeeded: v >> 8))
        data.append(UInt8(truncatingIfNeeded: v))
    }

    mutating func writeU32(_ v: UInt32) {
        data.append(UInt8(truncatingIfNeeded: v >> 24))
        data.append(UInt8(truncatingIfNeeded: v >> 16))
        data.append(UInt8(truncatingIfNeeded: v >> 8))
        data.append(UInt8(truncatingIfNeeded: v))
    }

    mutating func writeS32(_ v: Int32) { writeU32(UInt32(bitPattern: v)) }

    mutating func writeBytes(_ b: [UInt8]) { data.append(contentsOf: b) }

    mutating func writeData(_ d: Data) { data.append(d) }
}
