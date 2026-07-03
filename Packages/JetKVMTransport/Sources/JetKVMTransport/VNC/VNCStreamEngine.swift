import Foundation
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "vnc-stream")

/// Inbound clipboard traffic, routed to the backend's state machine. The
/// extended cases are populated in the Extended Clipboard phase; classic
/// ServerCutText is always available.
enum VNCInboundClipboard: Sendable {
    case classicText(String)
    case extended(VNCExtendedClipboard.Message)
}

/// The RFB server-message loop: reads `FramebufferUpdate`s, decodes each
/// rectangle into the persistent framebuffer **off the main actor**, and
/// presents the composed frame exactly once per complete update — RFB frames
/// updates (`number-of-rectangles` up front), so atomic presentation is
/// protocol-native and partial updates never reach the screen.
///
/// Runs inside one `Task.detached`; all mutable state is confined to it.
/// `@unchecked Sendable` only so the backend can hold a reference for lifecycle
/// control. It writes `FramebufferUpdateRequest`s back through the same channel
/// actor (which serializes them against input-event sends).
final class VNCStreamEngine: @unchecked Sendable {
    private let channel: any VNCByteChannel
    private let presenter: VideoFramePresenter
    private let framebuffer: VNCFramebuffer
    private let tight: TightDecoder
    private let zlib = ZlibDecoder()
    private let hextile = HextileDecoder()
    private let zrle = ZRLEDecoder()
    private let h264 = H264Decoder()
    private let stats: VNCStatsCollector

    /// Guards partial-update requests once a resize voids the framebuffer.
    private static let maxDimension = 16_384

    // Callbacks — set before `run()`; invoked from the decode task, so hop to
    // the main actor inside them.
    var onFrameSize: (@Sendable (Int, Int) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onClipboard: (@Sendable (VNCInboundClipboard) -> Void)?
    var onExtKeyEventAck: (@Sendable () -> Void)?
    /// Server XVP message: (code, version). code = INIT (1) advertises power
    /// control; FAIL (0) reports a rejected action.
    var onXVP: (@Sendable (_ code: UInt8, _ version: UInt8) -> Void)?

    /// Pause gate: when set, the engine stops requesting updates after the
    /// in-flight one completes (the server then goes quiet). Lock-guarded
    /// because `pauseVideo`/`resumeVideo` are called from the main actor.
    private let pauseLock = NSLock()
    private var _paused = false
    var paused: Bool {
        get { pauseLock.lock(); defer { pauseLock.unlock() }; return _paused }
        set { pauseLock.lock(); _paused = newValue; pauseLock.unlock() }
    }

    init(channel: any VNCByteChannel, presenter: VideoFramePresenter,
         width: Int, height: Int, pixelFormat: RFBProtocol.PixelFormat,
         stats: VNCStatsCollector) {
        self.channel = channel
        self.presenter = presenter
        self.framebuffer = VNCFramebuffer(width: width, height: height)
        self.tight = TightDecoder(pixelFormat: pixelFormat)
        self.stats = stats
    }

    func run() async {
        do {
            onFrameSize?(framebuffer.width, framebuffer.height)
            try await requestUpdate(incremental: false)
            while !Task.isCancelled {
                let type = try await readU8()
                switch RFBProtocol.ServerMessage(rawValue: type) {
                case .framebufferUpdate:
                    try await handleFramebufferUpdate()
                case .setColourMapEntries:
                    try await skipColourMapEntries()
                case .bell:
                    break // no-op
                case .serverCutText:
                    try await handleServerCutText()
                case .xvp:
                    try await handleServerXVP()
                case .none:
                    throw VNCConnectionError.protocolError("unknown server message type \(type)")
                }
            }
        } catch {
            if !Task.isCancelled {
                onError?("\(error)")
            }
        }
    }

    // MARK: - FramebufferUpdate

    private func handleFramebufferUpdate() async throws {
        _ = try await channel.readExactly(1) // padding
        let numRects = try await readU16()
        let openEnded = (numRects == 0xFFFF)

        var resized = false
        var dirty = false
        let start = ContinuousClock.now
        var index = 0
        loop: while openEnded || index < Int(numRects) {
            let header = try await readRectHeader()
            switch header.encoding {
            case RFBProtocol.Encoding.lastRect:
                break loop
            case RFBProtocol.Encoding.desktopSize:
                guard header.width <= Self.maxDimension, header.height <= Self.maxDimension else {
                    throw VNCConnectionError.protocolError("desktopSize too large \(header.width)x\(header.height)")
                }
                framebuffer.resize(width: header.width, height: header.height)
                onFrameSize?(framebuffer.width, framebuffer.height)
                resized = true
            case RFBProtocol.Encoding.qemuExtendedKeyEvent:
                // Empty pseudo-rect = server ack that it honours extended keys.
                onExtKeyEventAck?()
            case RFBProtocol.Encoding.raw:
                try await decodeRaw(header)
                stats.record(encoding: header.encoding)
                dirty = true
            case RFBProtocol.Encoding.copyRect:
                try await decodeCopyRect(header)
                stats.record(encoding: header.encoding)
                dirty = true
            case RFBProtocol.Encoding.tight:
                let jpeg = try await tight.decodeRect(header, channel: channel, framebuffer: framebuffer)
                stats.record(encoding: header.encoding, jpeg: jpeg)
                dirty = true
            case RFBProtocol.Encoding.zlib:
                try await zlib.decodeRect(header, channel: channel, framebuffer: framebuffer)
                stats.record(encoding: header.encoding)
                dirty = true
            case RFBProtocol.Encoding.hextile:
                try await hextile.decodeRect(header, channel: channel, framebuffer: framebuffer)
                stats.record(encoding: header.encoding)
                dirty = true
            case RFBProtocol.Encoding.zrle:
                try await zrle.decodeRect(header, channel: channel, framebuffer: framebuffer)
                stats.record(encoding: header.encoding)
                dirty = true
            case RFBProtocol.Encoding.h264:
                try await h264.decodeRect(header, channel: channel, framebuffer: framebuffer)
                stats.record(encoding: header.encoding)
                dirty = true
            default:
                throw VNCConnectionError.protocolError("unsupported encoding \(header.encoding)")
            }
            index += 1
        }

        if dirty || resized {
            present()
            let elapsed = ContinuousClock.now - start
            stats.record(frame: elapsed.seconds)
        }
        // Ask for the next update. After a resize the content is void, so ask
        // for a full (non-incremental) repaint.
        if !paused {
            try await requestUpdate(incremental: !resized)
        }
    }

    private func decodeRaw(_ h: RFBProtocol.RectHeader) async throws {
        guard framebuffer.contains(x: h.x, y: h.y, w: h.width, h: h.height) else {
            throw VNCConnectionError.protocolError("raw rect out of bounds")
        }
        let byteCount = h.width * h.height * VNCFramebuffer.bytesPerPixel
        let data = try await channel.readExactly(byteCount)
        try data.withUnsafeBytes { src in
            try framebuffer.blitBGRA(x: h.x, y: h.y, w: h.width, h: h.height, src: src)
        }
    }

    private func decodeCopyRect(_ h: RFBProtocol.RectHeader) async throws {
        var r = VNCByteReader(try await channel.readExactly(4))
        let srcX = Int(try r.readU16())
        let srcY = Int(try r.readU16())
        try framebuffer.copyRect(srcX: srcX, srcY: srcY, dstX: h.x, dstY: h.y, w: h.width, h: h.height)
    }

    private func present() {
        guard framebuffer.width > 0, framebuffer.height > 0 else { return }
        let w = framebuffer.width, h = framebuffer.height
        framebuffer.withPixelBytes { buf in
            presenter.present(source: buf, width: w, height: h, sourceBytesPerRow: framebuffer.bytesPerRow)
        }
    }

    // MARK: - Other server messages

    private func skipColourMapEntries() async throws {
        // padding(1) + first-colour(2) + number-of-colours(2), then 6 bytes each.
        let head = try await channel.readExactly(5)
        var r = VNCByteReader(head)
        _ = try r.readU8()
        _ = try r.readU16()
        let count = Int(try r.readU16())
        if count > 0 { _ = try await channel.readExactly(count * 6) }
    }

    private func handleServerCutText() async throws {
        // padding(3) + length(s32). Negative length = Extended Clipboard.
        let head = try await channel.readExactly(7)
        var r = VNCByteReader(head)
        _ = try r.readBytes(3)
        let rawLength = try r.readS32()
        if rawLength >= 0 {
            // Widen to Int before any arithmetic (Int32 length fields are
            // hostile input).
            let total = Int(rawLength)
            let n = min(total, 4 * 1024 * 1024)
            let body = n > 0 ? try await channel.readExactly(n) : Data()
            if total > n { _ = try await channel.readExactly(total - n) } // drain overflow
            let latin1 = String(bytes: body, encoding: .isoLatin1) ?? ""
            onClipboard?(.classicText(latin1))
        } else {
            // Widen THEN negate — negating Int32.min in Int32 would trap.
            let total = -Int(rawLength)
            let n = min(total, 8 * 1024 * 1024)
            let body = n > 0 ? try await channel.readExactly(n) : Data()
            if total > n { _ = try await channel.readExactly(total - n) }
            if let msg = try? VNCExtendedClipboard.parse(body) {
                onClipboard?(.extended(msg))
            }
        }
    }

    /// ServerXvp: padding(1) + version(1) + code(1).
    private func handleServerXVP() async throws {
        var r = VNCByteReader(try await channel.readExactly(3))
        _ = try r.readU8() // padding
        let version = try r.readU8()
        let code = try r.readU8()
        onXVP?(code, version)
    }

    // MARK: - Requests

    func requestUpdate(incremental: Bool) async throws {
        let data = RFBProtocol.framebufferUpdateRequest(
            incremental: incremental, x: 0, y: 0,
            width: framebuffer.width, height: framebuffer.height)
        try await channel.send(data)
    }

    // MARK: - Read helpers

    private func readU8() async throws -> UInt8 {
        try await channel.readExactly(1)[0]
    }

    private func readU16() async throws -> UInt16 {
        var r = VNCByteReader(try await channel.readExactly(2))
        return try r.readU16()
    }

    private func readRectHeader() async throws -> RFBProtocol.RectHeader {
        var r = VNCByteReader(try await channel.readExactly(12))
        return RFBProtocol.RectHeader(
            x: Int(try r.readU16()), y: Int(try r.readU16()),
            width: Int(try r.readU16()), height: Int(try r.readU16()),
            encoding: try r.readS32())
    }
}

private extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
