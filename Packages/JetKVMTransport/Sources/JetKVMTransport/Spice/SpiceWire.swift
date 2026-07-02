import Foundation

/// Little-endian binary reader/writer for the SPICE wire protocol.
///
/// SPICE structs are transmitted as packed, little-endian C structs
/// (see spice-protocol `protocol.h`). These helpers keep the channel code
/// free of manual byte fiddling and bounds checks.

/// Sequential little-endian reader over a `Data` buffer. Throws rather than
/// trapping on short reads so a malformed/truncated server message fails the
/// connection instead of crashing.
struct SpiceByteReader {
    enum Error: Swift.Error, Equatable {
        case outOfBounds(needed: Int, remaining: Int)
    }

    private let bytes: [UInt8]
    private(set) var offset: Int

    init(_ data: Data) {
        self.bytes = [UInt8](data)
        self.offset = 0
    }

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
    }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    private mutating func require(_ n: Int) throws {
        guard remaining >= n else {
            throw Error.outOfBounds(needed: n, remaining: remaining)
        }
    }

    mutating func readU8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readU16() throws -> UInt16 {
        try require(2)
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    mutating func readU32() throws -> UInt32 {
        try require(4)
        defer { offset += 4 }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (8 * i) }
        return v
    }

    mutating func readU64() throws -> UInt64 {
        try require(8)
        defer { offset += 8 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * i) }
        return v
    }

    mutating func readI8() throws -> Int8 { Int8(bitPattern: try readU8()) }
    mutating func readI16() throws -> Int16 { Int16(bitPattern: try readU16()) }
    mutating func readI32() throws -> Int32 { Int32(bitPattern: try readU32()) }

    mutating func readBytes(_ n: Int) throws -> [UInt8] {
        try require(n)
        defer { offset += n }
        return Array(bytes[offset..<(offset + n)])
    }

    /// Read a fixed-size field and skip trailing bytes (e.g. padded arrays).
    mutating func skip(_ n: Int) throws {
        try require(n)
        offset += n
    }

    /// Seek to an absolute offset (used to follow SPICE pointer fields, which
    /// are byte offsets from the start of the message body).
    mutating func seek(to absolute: Int) throws {
        guard absolute >= 0, absolute <= bytes.count else {
            throw Error.outOfBounds(needed: absolute, remaining: bytes.count)
        }
        offset = absolute
    }
}

/// Sequential little-endian writer.
struct SpiceByteWriter {
    private(set) var bytes: [UInt8] = []

    var data: Data { Data(bytes) }
    var count: Int { bytes.count }

    mutating func writeU8(_ v: UInt8) { bytes.append(v) }

    mutating func writeU16(_ v: UInt16) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
    }

    mutating func writeU32(_ v: UInt32) {
        for i in 0..<4 { bytes.append(UInt8((v >> (8 * i)) & 0xFF)) }
    }

    mutating func writeU64(_ v: UInt64) {
        for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) }
    }

    mutating func writeI8(_ v: Int8) { writeU8(UInt8(bitPattern: v)) }
    mutating func writeI16(_ v: Int16) { writeU16(UInt16(bitPattern: v)) }
    mutating func writeI32(_ v: Int32) { writeU32(UInt32(bitPattern: v)) }

    mutating func writeBytes(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    mutating func writeBytes(_ d: Data) { bytes.append(contentsOf: d) }
}
