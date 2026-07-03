import Foundation

/// Codec for the Extended Clipboard pseudo-encoding (the UTF-8-capable
/// replacement for Latin-1 cut text, negotiated via encoding
/// `RFBProtocol.Encoding.extendedClipboard`). Messages ride inside
/// Client/ServerCutText with a negative length; the payload starts with a flags
/// word, and `provide` bodies are one zlib (RFC 1950) stream.
///
/// Only the `text` format is implemented — it's all QEMU supports, and all the
/// pasteboard-sync feature needs.
enum VNCExtendedClipboard {
    struct Flags: OptionSet, Sendable {
        let rawValue: UInt32

        // Formats (bits 0-15)
        static let text = Flags(rawValue: 1 << 0)
        static let rtf = Flags(rawValue: 1 << 1)
        static let html = Flags(rawValue: 1 << 2)
        static let dib = Flags(rawValue: 1 << 3)
        static let files = Flags(rawValue: 1 << 4)

        // Actions (bits 24-28)
        static let caps = Flags(rawValue: 1 << 24)
        static let request = Flags(rawValue: 1 << 25)
        static let peek = Flags(rawValue: 1 << 26)
        static let notify = Flags(rawValue: 1 << 27)
        static let provide = Flags(rawValue: 1 << 28)

        static let formatMask = Flags(rawValue: 0xFFFF)
    }

    /// A decoded extended-clipboard message. Actions are mutually exclusive on
    /// the wire (one flag word per message).
    enum Message: Equatable, Sendable {
        /// Peer's capabilities: which actions it supports and, per format, the
        /// max size it accepts unsolicited (`provide` without a preceding
        /// `request`).
        case caps(actions: Flags, textMaxUnsolicitedSize: UInt32?)
        /// Peer wants us to `provide` the listed formats.
        case request(formats: Flags)
        /// Peer asks what we currently have; reply with `notify`.
        case peek
        /// Peer's clipboard changed; the listed formats are available.
        case notify(formats: Flags)
        /// Peer ships clipboard contents. Only text is surfaced.
        case provide(text: String?)
    }

    /// Cap on decompressed provide payloads. Text beyond this is dropped rather
    /// than ballooning memory from a hostile stream.
    static let maxProvideBytes = 8 * 1024 * 1024

    // MARK: - Parse (inbound ServerCutText with negative length)

    static func parse(_ payload: Data) throws -> Message {
        var r = VNCByteReader(payload)
        let flags = Flags(rawValue: try r.readU32())

        if flags.contains(.caps) {
            // One u32 max-size per advertised format, ascending bit order.
            var textMax: UInt32?
            for bit in 0..<16 where flags.rawValue & (1 << bit) != 0 {
                guard r.remaining >= 4 else { break } // tolerate short caps
                let size = try r.readU32()
                if bit == 0 { textMax = size }
            }
            return .caps(actions: flags, textMaxUnsolicitedSize: textMax)
        }
        if flags.contains(.provide) {
            let compressed = try r.readData(r.remaining)
            let raw = try ZlibCodec.inflate(compressed, limit: maxProvideBytes)
            var pr = VNCByteReader(raw)
            var text: String?
            for bit in 0..<16 where flags.rawValue & (1 << bit) != 0 {
                let size = Int(try pr.readU32())
                let data = try pr.readData(size)
                if bit == 0 { text = decodeText(data) } // text
            }
            return .provide(text: text)
        }
        if flags.contains(.request) {
            return .request(formats: flags.intersection(.formatMask))
        }
        if flags.contains(.peek) {
            return .peek
        }
        if flags.contains(.notify) {
            return .notify(formats: flags.intersection(.formatMask))
        }
        throw VNCConnectionError.protocolError("extended clipboard: no action flag (0x\(String(flags.rawValue, radix: 16)))")
    }

    // MARK: - Encode (outbound payloads; wrap with clientCutTextExtended)

    /// Our capabilities: text only, all actions. `textMaxUnsolicitedSize` lets
    /// the server skip the notify/request round-trip for small texts.
    static func encodeCaps(textMaxUnsolicitedSize: UInt32 = 1 << 20) -> Data {
        var w = VNCByteWriter()
        let flags: Flags = [.caps, .request, .peek, .notify, .provide, .text]
        w.writeU32(flags.rawValue)
        w.writeU32(textMaxUnsolicitedSize)
        return w.data
    }

    static func encodeNotify(hasText: Bool) -> Data {
        var w = VNCByteWriter()
        var flags: Flags = [.notify]
        if hasText { flags.insert(.text) }
        w.writeU32(flags.rawValue)
        return w.data
    }

    static func encodeRequestText() -> Data {
        var w = VNCByteWriter()
        w.writeU32(Flags([.request, .text]).rawValue)
        return w.data
    }

    static func encodeProvide(text: String) throws -> Data {
        var body = VNCByteWriter()
        let encoded = encodeText(text)
        body.writeU32(UInt32(encoded.count))
        body.writeData(encoded)
        let compressed = try ZlibCodec.deflate(body.data)

        var w = VNCByteWriter()
        w.writeU32(Flags([.provide, .text]).rawValue)
        w.writeData(compressed)
        return w.data
    }

    // MARK: - Text normalization

    /// Wire text is UTF-8 with CRLF line endings and a trailing NUL.
    static func encodeText(_ text: String) -> Data {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        var data = Data(normalized.utf8)
        data.append(0)
        return data
    }

    static func decodeText(_ data: Data) -> String? {
        var bytes = data
        if let nul = bytes.firstIndex(of: 0) {
            bytes = bytes.subdata(in: bytes.startIndex..<nul)
        }
        guard let raw = String(data: bytes, encoding: .utf8) else { return nil }
        return raw.replacingOccurrences(of: "\r\n", with: "\n")
    }
}
