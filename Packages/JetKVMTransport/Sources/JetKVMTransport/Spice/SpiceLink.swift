import Foundation

/// SPICE link-phase and data-framing codecs. Layouts from spice-protocol
/// `protocol.h`; all packed little-endian.

/// The 16-byte `SpiceLinkHeader` that prefixes both the client link message
/// and the server link reply.
struct SpiceLinkHeader {
    var major: UInt32
    var minor: UInt32
    /// Byte length of the body that follows this header.
    var size: UInt32

    func encode() -> Data {
        var w = SpiceByteWriter()
        w.writeBytes(SpiceProtocol.magic)   // 4 bytes "REDQ"
        w.writeU32(major)
        w.writeU32(minor)
        w.writeU32(size)
        return w.data
    }

    enum Error: Swift.Error, Equatable {
        case badMagic
        case versionMismatch(major: UInt32, minor: UInt32)
    }

    /// Parse and validate a 16-byte header.
    static func parse(_ data: Data) throws -> SpiceLinkHeader {
        var r = SpiceByteReader(data)
        let magic = try r.readBytes(4)
        guard magic == SpiceProtocol.magic else { throw Error.badMagic }
        let major = try r.readU32()
        let minor = try r.readU32()
        let size = try r.readU32()
        // The server echoes its protocol major; a mismatch is fatal.
        guard major == SpiceProtocol.versionMajor else {
            throw Error.versionMismatch(major: major, minor: minor)
        }
        return SpiceLinkHeader(major: major, minor: minor, size: size)
    }

    static let byteCount = 16
}

/// Client → server `SpiceLinkMess` + capability arrays, wrapped in a header.
struct SpiceLinkClientMessage {
    var connectionID: UInt32
    var channelType: SpiceProtocol.ChannelType
    var channelID: UInt8
    var commonCaps: SpiceCaps
    var channelCaps: SpiceCaps

    /// `sizeof(SpiceLinkMess)` — caps_offset points here.
    private static let messByteCount = 18

    /// Full framed bytes: header + mess + common caps + channel caps.
    func encode() -> Data {
        var mess = SpiceByteWriter()
        mess.writeU32(connectionID)
        mess.writeU8(channelType.rawValue)
        mess.writeU8(channelID)
        mess.writeU32(UInt32(commonCaps.wordCount))
        mess.writeU32(UInt32(channelCaps.wordCount))
        mess.writeU32(UInt32(Self.messByteCount))   // caps_offset
        for word in commonCaps.words { mess.writeU32(word) }
        for word in channelCaps.words { mess.writeU32(word) }

        let header = SpiceLinkHeader(
            major: SpiceProtocol.versionMajor,
            minor: SpiceProtocol.versionMinor,
            size: UInt32(mess.count)
        )
        var out = SpiceByteWriter()
        out.writeBytes(header.encode())
        out.writeBytes(mess.data)
        return out.data
    }
}

/// Server → client `SpiceLinkReply` body (the bytes after the header).
struct SpiceLinkReply: Equatable {
    var error: UInt32
    var pubKey: [UInt8]        // DER SubjectPublicKeyInfo, 162 bytes
    var commonCaps: SpiceCaps
    var channelCaps: SpiceCaps

    /// error(4) + pubkey(162) + num_common(4) + num_channel(4) + caps_offset(4)
    private static let fixedByteCount = 4 + 162 + 4 + 4 + 4   // 178

    enum Error: Swift.Error, Equatable { case truncated }

    static func parse(_ body: Data) throws -> SpiceLinkReply {
        var r = SpiceByteReader(body)
        let error = try r.readU32()
        let pubKey = try r.readBytes(SpiceProtocol.ticketPubkeyBytes)
        let numCommon = try r.readU32()
        let numChannel = try r.readU32()
        let capsOffset = try r.readU32()

        // Seek to caps_offset (relative to the start of the reply struct).
        var capsReader = SpiceByteReader(body)
        try capsReader.skip(Int(capsOffset))
        let common = SpiceCaps(words: try (0..<Int(numCommon)).map { _ in try capsReader.readU32() })
        let channel = SpiceCaps(words: try (0..<Int(numChannel)).map { _ in try capsReader.readU32() })

        return SpiceLinkReply(error: error, pubKey: pubKey,
                              commonCaps: common, channelCaps: channel)
    }
}

/// Full 18-byte per-message header (used unless MINI_HEADER is negotiated).
struct SpiceDataHeader {
    var serial: UInt64
    var type: UInt16
    var size: UInt32
    var subList: UInt32

    static let byteCount = 18

    func encode() -> Data {
        var w = SpiceByteWriter()
        w.writeU64(serial)
        w.writeU16(type)
        w.writeU32(size)
        w.writeU32(subList)
        return w.data
    }

    static func parse(_ data: Data) throws -> SpiceDataHeader {
        var r = SpiceByteReader(data)
        return SpiceDataHeader(
            serial: try r.readU64(),
            type: try r.readU16(),
            size: try r.readU32(),
            subList: try r.readU32()
        )
    }
}

/// 6-byte header used when SPICE_COMMON_CAP_MINI_HEADER is negotiated.
struct SpiceMiniDataHeader {
    var type: UInt16
    var size: UInt32

    static let byteCount = 6

    func encode() -> Data {
        var w = SpiceByteWriter()
        w.writeU16(type)
        w.writeU32(size)
        return w.data
    }

    static func parse(_ data: Data) throws -> SpiceMiniDataHeader {
        var r = SpiceByteReader(data)
        return SpiceMiniDataHeader(type: try r.readU16(), size: try r.readU32())
    }
}
