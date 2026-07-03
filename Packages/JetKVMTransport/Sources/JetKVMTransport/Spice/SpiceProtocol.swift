import Foundation

/// SPICE wire constants, transcribed from the BSD-licensed spice-protocol
/// headers (`spice/protocol.h`, `spice/enums.h`). Kept in Swift so the
/// backend has no dependency on the C headers for protocol values.
enum SpiceProtocol {
    /// `*(uint32_t*)"REDQ"` — the 4 magic bytes, in wire (memory) order.
    static let magic: [UInt8] = Array("REDQ".utf8)   // R E D Q
    static let versionMajor: UInt32 = 2
    static let versionMinor: UInt32 = 2

    /// RSA key length used for the ticket (bits) and derived sizes.
    static let ticketKeyPairLengthBits = 1024
    /// DER SubjectPublicKeyInfo length the server sends in SpiceLinkReply.
    static let ticketPubkeyBytes = 1024 / 8 + 34      // 162
    /// Encrypted ticket length = RSA modulus size in bytes.
    static let ticketEncryptedBytes = 1024 / 8        // 128
    /// Max ticket (password) plaintext length, per the protocol.
    static let maxPasswordLength = 60

    /// Common capability bit indices (SpiceLinkMess common caps bitmask).
    enum CommonCap: UInt32 {
        case protocolAuthSelection = 0
        case authSpice = 1
        case authSasl = 2
        case miniHeader = 3
    }

    /// Auth mechanism selector sent when PROTOCOL_AUTH_SELECTION is used.
    /// Matches SPICE_COMMON_CAP_AUTH_SPICE.
    static let authMechanismSpice: UInt32 = CommonCap.authSpice.rawValue

    /// Display-channel capability bit indices (`SPICE_DISPLAY_CAP_*`).
    /// Advertised in the display channel's link so the server streams video
    /// regions (instead of sending them as tiled image draws).
    enum DisplayCap: UInt32 {
        case sizedStream = 0
        case streamReport = 4
        case multiCodec = 8
        case codecMJPEG = 9
        case codecVP8 = 10
        case codecH264 = 11
        case codecVP9 = 13
        case codecH265 = 14
    }

    /// Video stream codec (`SPICE_VIDEO_CODEC_TYPE_*`) in STREAM_CREATE.
    enum VideoCodec: UInt8 {
        case mjpeg = 1
        case vp8 = 2
        case h264 = 3
        case vp9 = 4
        case h265 = 5
    }

    /// Channel types (`SPICE_CHANNEL_*`). Stable protocol values.
    enum ChannelType: UInt8 {
        case main = 1
        case display = 2
        case inputs = 3
        case cursor = 4
        case playback = 5
        case record = 6
        case tunnel = 7
        case smartcard = 8
        case usbredir = 9
        case port = 10
        case webdav = 11
    }

    /// Link handshake result / error codes (`spice/error_codes.h`).
    enum LinkErr: UInt32 {
        case ok = 0
        case error = 1
        case invalidMagic = 2
        case invalidData = 3
        case versionMismatch = 4
        case needSecured = 5
        case needUnsecured = 6
        case permissionDenied = 7
        case badConnectionID = 8
        case channelNotAvailable = 9
    }

    /// Mouse modes (`SPICE_MOUSE_MODE_*`), used by the main + inputs channels.
    enum MouseMode: UInt32 {
        case server = 1   // relative motion
        case client = 2   // absolute position (needs agent/tablet)
    }
}

/// A parsed capabilities bitmask (array of little-endian u32 words). SPICE
/// encodes each capability as a bit index; word = index / 32, bit = index % 32.
struct SpiceCaps: Equatable {
    private(set) var words: [UInt32]

    init(words: [UInt32] = []) { self.words = words }

    /// Build from a set of capability bit indices.
    init(bits: [UInt32]) {
        var words: [UInt32] = []
        for bit in bits {
            let word = Int(bit / 32)
            if word >= words.count {
                words.append(contentsOf: repeatElement(0, count: word - words.count + 1))
            }
            words[word] |= (1 << (bit % 32))
        }
        self.words = words
    }

    func has(_ bit: UInt32) -> Bool {
        let word = Int(bit / 32)
        guard word < words.count else { return false }
        return (words[word] & (1 << (bit % 32))) != 0
    }

    var wordCount: Int { words.count }
}
