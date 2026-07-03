import Foundation

/// RFB 3.8 protocol constants, the negotiated pixel format, and client-message
/// builders. Pure data — no I/O — so the wire format is unit-testable without a
/// socket.
enum RFBProtocol {
    /// The protocol version we advertise. QEMU (and everything modern)
    /// negotiates 3.8; we tolerate a server that pins 3.7 (see `VNCConnection`).
    static let versionString = "RFB 003.008\n"
    static let versionByteCount = 12

    // MARK: - Security

    enum SecurityType: UInt8 {
        case invalid = 0
        case none = 1
        case vncAuth = 2
        case veNCrypt = 19
    }

    /// VeNCrypt (security type 19): a plaintext sub-negotiation that selects a
    /// subtype, then upgrades the socket to TLS in-band; the inner auth
    /// (None/VNCAuth/Plain) and the rest of RFB then run inside TLS.
    enum VeNCrypt {
        static let version: (major: UInt8, minor: UInt8) = (0, 2)

        // Subtypes.
        static let plain: UInt32 = 256      // userpass, NO TLS — refused
        static let tlsNone: UInt32 = 257
        static let tlsVnc: UInt32 = 258
        static let tlsPlain: UInt32 = 259
        static let x509None: UInt32 = 260
        static let x509Vnc: UInt32 = 261
        static let x509Plain: UInt32 = 262

        /// Inner authentication implied by a subtype.
        enum InnerAuth: Equatable, Sendable {
            case none
            case vnc      // VNC Auth (DES) inside TLS
            case plain    // username + password inside TLS
        }

        static func innerAuth(for subtype: UInt32) -> InnerAuth? {
            switch subtype {
            case tlsNone, x509None: return InnerAuth.none
            case tlsVnc, x509Vnc: return .vnc
            case tlsPlain, x509Plain: return .plain
            default: return nil
            }
        }

        /// Subtypes we accept, strongest-and-safest first. All are TLS-wrapped
        /// (we refuse the unencrypted `plain` subtype). `hasUsername` gates the
        /// Plain subtypes, `hasPassword` gates Plain and Vnc.
        static func preferredSubtypes(hasUsername: Bool, hasPassword: Bool) -> [UInt32] {
            var order: [UInt32] = []
            if hasUsername && hasPassword { order += [x509Plain, tlsPlain] }
            if hasPassword { order += [x509Vnc, tlsVnc] }
            order += [x509None, tlsNone]
            return order
        }
    }

    // MARK: - Message types

    enum ServerMessage: UInt8 {
        case framebufferUpdate = 0
        case setColourMapEntries = 1
        case bell = 2
        case serverCutText = 3
        /// XVP power-control (server → client): INIT advertises support, FAIL
        /// reports a rejected action.
        case xvp = 250
    }

    enum ClientMessage: UInt8 {
        case setPixelFormat = 0
        case setEncodings = 2
        case framebufferUpdateRequest = 3
        case keyEvent = 4
        case pointerEvent = 5
        case clientCutText = 6
        /// XVP power-control action (client → server).
        case xvp = 250
        /// QEMU client-message family; submessage 0 = extended key event.
        case qemu = 255
    }

    /// XVP (power control) constants. The client advertises the XVP
    /// pseudo-encoding; a server started with power control on replies with an
    /// XVP `init`, after which the client may send shutdown/reboot/reset.
    enum XVP {
        static let version: UInt8 = 1
        static let codeFail: UInt8 = 0
        static let codeInit: UInt8 = 1
        static let actionShutdown: UInt8 = 2
        static let actionReboot: UInt8 = 3
        static let actionReset: UInt8 = 4
    }

    // MARK: - Encodings

    enum Encoding {
        static let raw: Int32 = 0
        static let copyRect: Int32 = 1
        static let hextile: Int32 = 5
        static let zlib: Int32 = 6
        static let tight: Int32 = 7
        static let zrle: Int32 = 16
        /// RFB "Open H.264" encoding (PiKVM kvmd-vnc, TigerVNC 1.13+, patched QEMU).
        static let h264: Int32 = 50

        // Pseudo-encodings.
        static let desktopSize: Int32 = -223
        static let lastRect: Int32 = -224
        static let qemuPointerMotionChange: Int32 = -257
        static let qemuExtendedKeyEvent: Int32 = -258
        /// XVP power control (0xFFFFFECB).
        static let xvp = Int32(bitPattern: 0xFFFF_FECB)
        /// VNC Extended Clipboard (0xC0A1E5CE as a signed 32-bit value).
        static let extendedClipboard = Int32(bitPattern: 0xC0A1_E5CE)

        /// Tight compression-level pseudo-encoding for level 0…9 (−256…−247).
        static func compressionLevel(_ level: Int) -> Int32 { -256 + Int32(clamping: level) }
        /// Tight JPEG-quality pseudo-encoding for quality 0…9 (−32…−23).
        static func jpegQuality(_ quality: Int) -> Int32 { -32 + Int32(clamping: quality) }
    }

    // MARK: - Pixel format

    /// The RFB `PIXEL_FORMAT` (16 bytes on the wire).
    struct PixelFormat: Equatable {
        var bitsPerPixel: UInt8
        var depth: UInt8
        var bigEndian: Bool
        var trueColor: Bool
        var redMax: UInt16
        var greenMax: UInt16
        var blueMax: UInt16
        var redShift: UInt8
        var greenShift: UInt8
        var blueShift: UInt8

        static let byteCount = 16

        /// The format we force via `SetPixelFormat`. 32bpp, depth 24,
        /// little-endian, true-colour with R at bits 16-23, G at 8-15, B at
        /// 0-7. On a little-endian host the wire bytes of each pixel are then
        /// B, G, R, X — exactly `kCVPixelFormatType_32BGRA` memory order — so a
        /// Raw rect blits with a straight `memcpy`, and Tight qualifies for the
        /// compact 3-byte TPIXEL form.
        static let bgra32 = PixelFormat(
            bitsPerPixel: 32, depth: 24, bigEndian: false, trueColor: true,
            redMax: 255, greenMax: 255, blueMax: 255,
            redShift: 16, greenShift: 8, blueShift: 0
        )

        func encode(into w: inout VNCByteWriter) {
            w.writeU8(bitsPerPixel)
            w.writeU8(depth)
            w.writeU8(bigEndian ? 1 : 0)
            w.writeU8(trueColor ? 1 : 0)
            w.writeU16(redMax)
            w.writeU16(greenMax)
            w.writeU16(blueMax)
            w.writeU8(redShift)
            w.writeU8(greenShift)
            w.writeU8(blueShift)
            w.writeBytes([0, 0, 0]) // padding
        }

        static func parse(_ r: inout VNCByteReader) throws -> PixelFormat {
            let bpp = try r.readU8()
            let depth = try r.readU8()
            let big = try r.readU8() != 0
            let tc = try r.readU8() != 0
            let rMax = try r.readU16()
            let gMax = try r.readU16()
            let bMax = try r.readU16()
            let rShift = try r.readU8()
            let gShift = try r.readU8()
            let bShift = try r.readU8()
            _ = try r.readBytes(3) // padding
            return PixelFormat(
                bitsPerPixel: bpp, depth: depth, bigEndian: big, trueColor: tc,
                redMax: rMax, greenMax: gMax, blueMax: bMax,
                redShift: rShift, greenShift: gShift, blueShift: bShift
            )
        }

        /// Whether Tight may use the compact 3-byte TPIXEL form (true-colour,
        /// 32bpp, depth 24, 8-bit channels placed in the low 24 bits).
        var tpixelCompact: Bool {
            trueColor && bitsPerPixel == 32 && depth == 24
                && redMax == 255 && greenMax == 255 && blueMax == 255
                && Set([redShift, greenShift, blueShift]) == [0, 8, 16]
        }
    }

    /// The server's `ServerInit` reply: framebuffer size, its pixel format, and
    /// desktop name.
    struct ServerInit: Equatable {
        var width: Int
        var height: Int
        var pixelFormat: PixelFormat
        var name: String
    }

    /// One rectangle header inside a `FramebufferUpdate`.
    struct RectHeader: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        var encoding: Int32
    }

    // MARK: - Client message builders

    static func setPixelFormat(_ pf: PixelFormat) -> Data {
        var w = VNCByteWriter()
        w.writeU8(ClientMessage.setPixelFormat.rawValue)
        w.writeBytes([0, 0, 0]) // padding
        pf.encode(into: &w)
        return w.data
    }

    static func setEncodings(_ encodings: [Int32]) -> Data {
        var w = VNCByteWriter()
        w.writeU8(ClientMessage.setEncodings.rawValue)
        w.writeU8(0) // padding
        w.writeU16(UInt16(encodings.count))
        for e in encodings { w.writeS32(e) }
        return w.data
    }

    static func framebufferUpdateRequest(
        incremental: Bool, x: Int, y: Int, width: Int, height: Int
    ) -> Data {
        var w = VNCByteWriter()
        w.writeU8(ClientMessage.framebufferUpdateRequest.rawValue)
        w.writeU8(incremental ? 1 : 0)
        w.writeU16(UInt16(clamping: x))
        w.writeU16(UInt16(clamping: y))
        w.writeU16(UInt16(clamping: width))
        w.writeU16(UInt16(clamping: height))
        return w.data
    }

    static func keyEvent(keysym: UInt32, down: Bool) -> Data {
        var w = VNCByteWriter()
        w.writeU8(ClientMessage.keyEvent.rawValue)
        w.writeU8(down ? 1 : 0)
        w.writeU16(0) // padding
        w.writeU32(keysym)
        return w.data
    }

    /// QEMU Extended Key Event (message 255, submessage 0): carries the XT
    /// keycode alongside the keysym so the guest maps keys layout-independently.
    static func qemuExtendedKeyEvent(keysym: UInt32, keycode: UInt32, down: Bool) -> Data {
        var w = VNCByteWriter()
        w.writeU8(ClientMessage.qemu.rawValue)
        w.writeU8(0) // submessage type: extended key event
        w.writeU16(down ? 1 : 0)
        w.writeU32(keysym)
        w.writeU32(keycode)
        return w.data
    }

    static func pointerEvent(buttonMask: UInt8, x: Int, y: Int) -> Data {
        var w = VNCByteWriter()
        w.writeU8(ClientMessage.pointerEvent.rawValue)
        w.writeU8(buttonMask)
        w.writeU16(UInt16(clamping: x))
        w.writeU16(UInt16(clamping: y))
        return w.data
    }

    /// VeNCrypt "Plain" inner auth (sent inside TLS): u32 user-length,
    /// u32 password-length, then the UTF-8 username and password bytes.
    static func veNCryptPlainAuth(username: String, password: String) -> Data {
        let user = Array(username.utf8)
        let pass = Array(password.utf8)
        var w = VNCByteWriter()
        w.writeU32(UInt32(user.count))
        w.writeU32(UInt32(pass.count))
        w.writeBytes(user)
        w.writeBytes(pass)
        return w.data
    }

    /// Client XVP power-control message: type(250), padding, version, action.
    static func xvp(action: UInt8) -> Data {
        var w = VNCByteWriter()
        w.writeU8(ClientMessage.xvp.rawValue)
        w.writeU8(0) // padding
        w.writeU8(XVP.version)
        w.writeU8(action)
        return w.data
    }

    /// Classic ClientCutText (Latin-1). Non-Latin-1 code points are dropped by
    /// the lossy conversion; use the Extended Clipboard path for UTF-8.
    static func clientCutText(latin1 text: String) -> Data {
        let bytes = [UInt8](text.unicodeScalars.map { $0.value <= 0xFF ? UInt8($0.value) : UInt8(ascii: "?") })
        var w = VNCByteWriter()
        w.writeU8(ClientMessage.clientCutText.rawValue)
        w.writeBytes([0, 0, 0]) // padding
        w.writeU32(UInt32(bytes.count))
        w.writeBytes(bytes)
        return w.data
    }

    /// Extended ClientCutText: the length field is the negated payload length,
    /// signalling an Extended Clipboard message body (built elsewhere).
    static func clientCutTextExtended(payload: Data) -> Data {
        var w = VNCByteWriter()
        w.writeU8(ClientMessage.clientCutText.rawValue)
        w.writeBytes([0, 0, 0]) // padding
        w.writeS32(-Int32(payload.count))
        w.writeData(payload)
        return w.data
    }
}
