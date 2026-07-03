import Foundation
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "spice-display")

/// A decoded primary-surface frame handed to the renderer. Value type (owns
/// its pixel copy) so it crosses actors safely.
struct SpiceFrame: Sendable {
    let width: Int
    let height: Int
    let bgra: [UInt8]
}

/// The SPICE display channel: sends DISPLAY_INIT, maintains drawing surfaces,
/// composites the draw ops we support (DRAW_COPY, DRAW_FILL) via
/// `SpiceImageDecoder`, and emits primary-surface frames.
///
/// Emission is coalesced: draw ops mutate the surface, and a ~60 Hz timer
/// snapshots the primary surface only when it changed. Emitting per draw op
/// instead showed partial, tile-by-tile updates (a left-to-right "swipe" on
/// video) and copied the whole framebuffer for every tile.
///
/// v1 handles surface create/destroy, mode, reset, and image copies/fills
/// (QUIC/LZ/GLZ/JPEG/bitmap, with the client image cache). Video streams and
/// the less-common draw ops (stroke/text/rop3/…) are not yet composited.
final class SpiceDisplayChannel: SpiceChannel {
    /// Fired at ~60 Hz with a fresh copy of the primary surface when it changed.
    var onFrame: (@Sendable (SpiceFrame) -> Void)?

    // `lock` guards surfaces / primaryID / dirty, shared between the read loop
    // (handle) and the emit timer.
    private let lock = NSLock()
    private var surfaces: [UInt32: SpiceSurface] = [:]
    private var primaryID: UInt32?
    private var dirty = false

    /// Active video streams by id: codec + current destination rect on the
    /// primary surface. Guarded by `lock`.
    private struct Stream { var codec: SpiceProtocol.VideoCodec?; var dest: SpiceRect }
    private var streams: [UInt32: Stream] = [:]
    /// One H.264 decoder per H.264 stream. Touched only on the read loop.
    private var h264Decoders: [UInt32: SpiceH264Decoder] = [:]

    private let decoder = SpiceImageDecoder()

    private let timerQueue = DispatchQueue(label: "app.regi.mac.spice-display-emit")
    private var frameTimer: DispatchSourceTimer?
    private static let frameInterval = DispatchTimeInterval.milliseconds(16)   // ~60 Hz

    override func start() {
        super.start()
        Task { [weak self] in await self?.sendDisplayInit() }
        startFrameTimer()
    }

    override func stop() {
        frameTimer?.cancel()
        frameTimer = nil
        super.stop()
    }

    private func startFrameTimer() {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + Self.frameInterval, repeating: Self.frameInterval)
        timer.setEventHandler { [weak self] in self?.emitIfDirty() }
        timer.resume()
        frameTimer = timer
    }

    /// Decode a video-stream frame and composite it onto the primary surface
    /// at the stream's destination rect. Called from the read loop, so the
    /// decoder (serial) is safe to touch outside the lock.
    private func blitStreamFrame(streamID: UInt32, data: [UInt8], dest destOverride: SpiceRect?) {
        lock.lock()
        guard var stream = streams[streamID] else { lock.unlock(); return }
        if let destOverride { stream.dest = destOverride; streams[streamID] = stream }
        let codec = stream.codec
        let dest = stream.dest
        lock.unlock()

        let decodedFrame: SpiceImageDecoder.Decoded?
        switch codec {
        case .mjpeg: decodedFrame = decoder.decodeMJPEGFrame(data)
        case .h264:  decodedFrame = h264Decoders[streamID]?.decode(data)
        default:     decodedFrame = nil     // VP8/VP9/H265 not yet supported
        }
        guard let frame = decodedFrame else { return }

        lock.lock()
        if let id = primaryID, let surface = surfaces[id] {
            surface.blit(src: frame.pixels, srcWidth: frame.width, srcHeight: frame.height,
                         srcArea: SpiceRect(top: 0, left: 0,
                                            bottom: Int32(frame.height), right: Int32(frame.width)),
                         dest: dest)
            dirty = true
        }
        lock.unlock()
    }

    /// Snapshot + emit the primary surface if it changed since the last emit.
    /// Internal so tests can drive it deterministically without the timer.
    func emitIfDirty() {
        lock.lock()
        guard dirty, let id = primaryID, let surface = surfaces[id] else {
            lock.unlock()
            return
        }
        dirty = false
        let frame = SpiceFrame(width: surface.width, height: surface.height, bgra: surface.pixels)
        lock.unlock()
        onFrame?(frame)
    }

    private func sendDisplayInit() async {
        // init: pixmap_cache_id u8, pixmap_cache_size i64 (pixels),
        //       glz_dictionary_id u8, glz_dictionary_window_size i32 (pixels).
        var w = SpiceByteWriter()
        w.writeU8(1)
        w.writeU64(UInt64(4 * 1024 * 1024))    // ~4M pixels
        w.writeU8(1)
        w.writeU32(UInt32(1024 * 1024))        // 1M-pixel GLZ window
        try? await send(type: SpiceMsg.DisplayClient.initMsg.rawValue, payload: w.data)

        // Tell the server which video codecs we can decode, in preference
        // order. Modern (gstreamer) servers advertise PREF_VIDEO_CODEC_TYPE
        // and only stream video once they receive this — the legacy CODEC_*
        // caps are ignored. Payload: num_codecs (u8) + codec types (u8 each).
        var codecs = SpiceByteWriter()
        let preferred: [SpiceProtocol.VideoCodec] = [.h264, .mjpeg]
        codecs.writeU8(UInt8(preferred.count))
        for c in preferred { codecs.writeU8(c.rawValue) }
        try? await send(type: SpiceMsg.DisplayClient.preferredVideoCodecType.rawValue, payload: codecs.data)
    }

    override func handle(type: UInt16, payload: Data) async {
        guard let msg = SpiceMsg.Display(rawValue: type) else { return }
        do {
            switch msg {
            case .surfaceCreate:
                let s = try SpiceMsgSurfaceCreate.parse(payload)
                lock.lock()
                surfaces[s.surfaceID] = SpiceSurface(width: Int(s.width), height: Int(s.height))
                if s.isPrimary { primaryID = s.surfaceID }
                lock.unlock()
                log.debug("surface \(s.surfaceID) create \(s.width)x\(s.height) primary=\(s.isPrimary)")

            case .surfaceDestroy:
                let d = try SpiceMsgSurfaceDestroy.parse(payload)
                lock.lock()
                surfaces[d.surfaceID] = nil
                if primaryID == d.surfaceID { primaryID = nil }
                lock.unlock()

            case .mode:
                // Legacy single-surface path: x_res, y_res, bits. Create a
                // primary surface if the server didn't send SURFACE_CREATE.
                var r = SpiceByteReader(payload)
                let xres = try r.readU32(), yres = try r.readU32()
                lock.lock()
                if primaryID == nil {
                    surfaces[0] = SpiceSurface(width: Int(xres), height: Int(yres))
                    primaryID = 0
                }
                lock.unlock()

            case .reset:
                lock.lock()
                surfaces.removeAll()
                streams.removeAll()
                primaryID = nil
                dirty = false
                lock.unlock()
                h264Decoders.removeAll()
                decoder.reset()

            case .streamCreate:
                let s = try SpiceMsgStreamCreate.parse(payload)
                lock.lock()
                streams[s.streamID] = Stream(codec: s.codec, dest: s.dest)
                lock.unlock()
                if s.codec == .h264 { h264Decoders[s.streamID] = SpiceH264Decoder() }

            case .streamData:
                let d = try SpiceMsgStreamData.parse(payload)
                blitStreamFrame(streamID: d.streamID, data: d.data, dest: nil)

            case .streamDataSized:
                let d = try SpiceMsgStreamDataSized.parse(payload)
                blitStreamFrame(streamID: d.streamID, data: d.data, dest: d.dest)

            case .streamDestroy:
                let d = try SpiceMsgStreamDestroy.parse(payload)
                lock.lock(); streams[d.streamID] = nil; lock.unlock()
                h264Decoders[d.streamID] = nil

            case .streamDestroyAll:
                lock.lock(); streams.removeAll(); lock.unlock()
                h264Decoders.removeAll()

            case .drawFill:
                let fill = try SpiceDrawFill.parse(payload)
                guard let color = fill.solidColor else { return }
                lock.lock()
                if let surface = surfaces[fill.base.surfaceID] {
                    surface.fill(rect: fill.base.box, color: color)
                    if fill.base.surfaceID == primaryID { dirty = true }
                }
                lock.unlock()

            case .drawCopy:
                let copy = try SpiceDrawCopy.parse(payload)
                guard let image = copy.image else { return }
                // Decode outside the lock (the decoder is only touched here).
                let decoded = decoder.decode(image)
                lock.lock()
                if let decoded, let surface = surfaces[copy.base.surfaceID] {
                    surface.blit(src: decoded.pixels, srcWidth: decoded.width, srcHeight: decoded.height,
                                 srcArea: copy.srcArea, dest: copy.base.box)
                    if copy.base.surfaceID == primaryID { dirty = true }
                }
                lock.unlock()

            default:
                break   // streams + uncommon draw ops: v1 skips
            }
        } catch {
            log.debug("display message \(type) parse failed: \(String(describing: error), privacy: .public)")
        }
    }
}
