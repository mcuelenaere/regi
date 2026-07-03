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
    /// We snapshot the surface only once the read loop has been *blocked*
    /// waiting for the next message for `quietNanos` — i.e. the current batch
    /// of draw ops is fully applied. QEMU's spice display sends one batch of
    /// 32px-wide column strips per GUI refresh tick (~30 ms) with no protocol
    /// end-of-frame marker, so tick boundaries are reconstructed from timing:
    /// the threshold must sit above normal network jitter *between* messages
    /// of one batch (WiFi commonly gaps 5-10 ms) but below the ~30 ms tick
    /// spacing. Too low ⇒ mid-batch presents (the left-to-right "wipe"); too
    /// high ⇒ ticks coalesce (harmless, just fewer presents).
    /// `maxLatencyNanos` is a safety valve so a pathological gapless stream
    /// still updates rather than freezing.
    private var lastEmitNanos: UInt64 = 0
    private static let quietNanos: UInt64 = 12_000_000         // > WiFi jitter, < QEMU tick
    private static let maxLatencyNanos: UInt64 = 200_000_000   // freeze-avoidance floor only
    /// The server's ACK window is small (~20 msgs), so a large redraw is sent
    /// in chunks separated by ACK round-trip stalls. We coalesce across a stall
    /// (don't present the partial frame) until either the server continues or
    /// the idle outlasts this grace — longer than any plausible round-trip, so
    /// a frame that genuinely ends on a chunk boundary still flushes.
    private static let ackStallGraceNanos: UInt64 = 60_000_000  // 60 ms

    /// Active video streams by id: codec + current destination rect on the
    /// primary surface. Guarded by `lock`.
    private struct Stream { var codec: SpiceProtocol.VideoCodec?; var dest: SpiceRect }
    private var streams: [UInt32: Stream] = [:]
    /// One H.264 decoder per H.264 stream. Touched only on the read loop.
    private var h264Decoders: [UInt32: SpiceH264Decoder] = [:]

    /// Per-stream STREAM_REPORT accounting, keyed by stream id. Populated when
    /// the server sends STREAM_ACTIVATE_REPORT; a report is emitted once the
    /// window (frames or timeout) fills. Servers throttle streams whose client
    /// advertised the report cap but stays silent, so this is what keeps the
    /// bitrate/framerate from collapsing. Guarded by `lock`.
    private struct ReportWindow {
        var uniqueID: UInt32
        var maxWindowSize: UInt32
        var timeoutMs: UInt32
        var started = false
        var numFrames: UInt32 = 0
        var numDrops: UInt32 = 0
        var startMMTime: UInt32 = 0
        var endMMTime: UInt32 = 0
        var windowStartNanos: UInt64 = 0
    }
    private var reportWindows: [UInt32: ReportWindow] = [:]

    private let decoder = SpiceImageDecoder()

    /// Cumulative display metrics, guarded by `lock`. The backend snapshots
    /// these ~1 Hz and derives per-interval rates (FPS, decode time). Video
    /// streams (STREAM_DATA) drive the codec/decode fields; screen updates of
    /// any kind (draw ops or streams) drive `emittedFrames`.
    struct Stats: Sendable {
        var emittedFrames = 0
        var streamFramesDecoded = 0
        var streamFramesDropped = 0
        var streamDecodeTimeSec = 0.0
        var codec: SpiceProtocol.VideoCodec?
        /// Latest stream-frame delivery delay (ms): how much later than the
        /// server's own frame schedule the frame reached us — i.e. buffering /
        /// network delay above the best case. 0 when no video is flowing.
        var frameDelayMs = 0.0
        /// Screen-updating draw ops received (FILL/COPY/OPAQUE/COPY_BITS) and
        /// stream (re)creations — for diagnosing where updates come from and
        /// whether the server's video-stream detector is flapping.
        var drawOps = 0
        var streamCreates = 0
    }
    private var stats = Stats()

    /// Baseline `(localArrivalMs − serverFrameMMTimeMs)` — the minimum offset
    /// seen, which cancels the unknown clock difference so `frameDelayMs` is
    /// delay *above best case*. Guarded by `lock`.
    private var mmOffsetBaselineMs: Double?

    /// Thread-safe snapshot of the cumulative display metrics.
    func statsSnapshot() -> Stats { lock.lock(); defer { lock.unlock() }; return stats }

    private let timerQueue = DispatchQueue(label: "app.regi.mac.spice-display-emit")
    private var frameTimer: DispatchSourceTimer?
    private static let frameInterval = DispatchTimeInterval.milliseconds(4)   // poll for burst settle

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
    /// decoder (serial) is safe to touch outside the lock. Returns a
    /// STREAM_REPORT payload to send back when the report window has filled
    /// (nil otherwise); the async caller does the send.
    private func blitStreamFrame(streamID: UInt32, data: [UInt8], mmTime: UInt32,
                                 dest destOverride: SpiceRect?) -> Data? {
        lock.lock()
        guard var stream = streams[streamID] else { lock.unlock(); return nil }
        if let destOverride { stream.dest = destOverride; streams[streamID] = stream }
        let codec = stream.codec
        let dest = stream.dest
        lock.unlock()

        let t0 = DispatchTime.now().uptimeNanoseconds
        let decodedFrame: SpiceImageDecoder.Decoded?
        switch codec {
        case .mjpeg: decodedFrame = decoder.decodeMJPEGFrame(data)
        case .h264:  decodedFrame = h264Decoders[streamID]?.decode(data)
        default:     decodedFrame = nil     // VP8/VP9/H265 not yet supported
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let decodeSec = Double(now - t0) / 1_000_000_000

        lock.lock()
        defer { lock.unlock() }
        stats.codec = codec
        stats.streamDecodeTimeSec += decodeSec
        if decodedFrame == nil { stats.streamFramesDropped += 1 } else { stats.streamFramesDecoded += 1 }
        // Delivery delay: offset of local arrival from the server's frame clock,
        // minus the running-minimum offset (which cancels the fixed clock skew).
        let offsetMs = Double(now) / 1_000_000 - Double(mmTime)
        if mmOffsetBaselineMs == nil || offsetMs < mmOffsetBaselineMs! { mmOffsetBaselineMs = offsetMs }
        stats.frameDelayMs = offsetMs - (mmOffsetBaselineMs ?? offsetMs)
        if let frame = decodedFrame, let id = primaryID, let surface = surfaces[id] {
            surface.blit(src: frame.pixels, srcWidth: frame.width, srcHeight: frame.height,
                         srcArea: SpiceRect(top: 0, left: 0,
                                            bottom: Int32(frame.height), right: Int32(frame.width)),
                         dest: dest)
            dirty = true
        }
        return accumulateReport(streamID: streamID, mmTime: mmTime,
                                dropped: decodedFrame == nil, now: now)
    }

    /// Fold one stream frame into its report window (caller holds `lock`).
    /// Returns a STREAM_REPORT payload when the window fills, else nil.
    private func accumulateReport(streamID: UInt32, mmTime: UInt32,
                                  dropped: Bool, now: UInt64) -> Data? {
        guard var w = reportWindows[streamID] else { return nil }
        if !w.started {
            w.started = true
            w.numFrames = 0; w.numDrops = 0
            w.startMMTime = mmTime
            w.windowStartNanos = now
        }
        w.endMMTime = mmTime
        w.numFrames += 1
        if dropped { w.numDrops += 1 }

        let elapsedMs = (now - w.windowStartNanos) / 1_000_000
        let due = w.numFrames >= w.maxWindowSize || (w.timeoutMs > 0 && elapsedMs >= w.timeoutMs)
        guard due else { reportWindows[streamID] = w; return nil }

        // Report perfect keep-up: 0 client-side delay, no audio (UINT32_MAX).
        let payload = SpiceByteWriter.streamReport(
            streamID: streamID, uniqueID: w.uniqueID,
            startFrameMMTime: w.startMMTime, endFrameMMTime: w.endMMTime,
            numFrames: w.numFrames, numDrops: w.numDrops,
            lastFrameDelay: 0, audioDelay: .max)
        w.started = false
        reportWindows[streamID] = w
        return payload
    }

    /// Mark the primary surface changed. Caller holds `lock`.
    private func markDirtyLocked() {
        dirty = true
    }

    /// Snapshot + emit the primary surface, but only once the read loop has been
    /// blocked on the server for `quietNanos` (the batch is fully applied), so
    /// we never publish a half-drawn frame. The `maxLatencyNanos` cap only fires
    /// if the server somehow never pauses. Polled by the timer; internal so
    /// tests can drive it deterministically.
    func emitIfDirty() {
        let now = DispatchTime.now().uptimeNanoseconds
        let blockedSince = receiveBlockedSinceNanos
        let idleFor = blockedSince != 0 ? now &- blockedSince : 0
        let batchDone = blockedSince != 0 && idleFor >= Self.quietNanos
        // If the last message hit the ACK window, this idle is almost certainly
        // the server parked waiting for our ACK to keep sending the same frame —
        // presenting now would show it half-drawn (the window "wipe"). Hold off
        // until the server continues, or the idle clearly outlasts a round-trip.
        let ackStall = lastMessageHitAckWindow && idleFor < Self.ackStallGraceNanos
        let latencyCap = now &- lastEmitNanos >= Self.maxLatencyNanos
        guard (batchDone && !ackStall) || latencyCap else { return }
        snapshotAndEmit()
    }

    /// Take the lock, and if dirty, snapshot the primary surface and emit it.
    private func snapshotAndEmit() {
        lock.lock()
        guard dirty, let id = primaryID, let surface = surfaces[id] else {
            lock.unlock()
            return
        }
        dirty = false
        lastEmitNanos = DispatchTime.now().uptimeNanoseconds
        stats.emittedFrames += 1
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
        log.notice("SPICE sent preferred video codecs: \(preferred.map { String(describing: $0) }.joined(separator: ">"), privacy: .public)")
    }

    override func handle(type: UInt16, payload: Data) async {
        guard let msg = SpiceMsg.Display(rawValue: type) else {
            logUnhandled(type: type, name: "unknown")
            return
        }
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
                reportWindows.removeAll()
                mmOffsetBaselineMs = nil
                primaryID = nil
                dirty = false
                lock.unlock()
                h264Decoders.removeAll()
                decoder.reset()

            case .streamCreate:
                let s = try SpiceMsgStreamCreate.parse(payload)
                lock.lock()
                streams[s.streamID] = Stream(codec: s.codec, dest: s.dest)
                stats.streamCreates += 1
                lock.unlock()
                if s.codec == .h264 { h264Decoders[s.streamID] = SpiceH264Decoder() }
                log.notice("SPICE stream \(s.streamID) created codec=\(String(describing: s.codec), privacy: .public) \(s.dest.width)x\(s.dest.height)")

            case .streamData:
                let d = try SpiceMsgStreamData.parse(payload)
                if let report = blitStreamFrame(streamID: d.streamID, data: d.data,
                                                mmTime: d.multiMediaTime, dest: nil) {
                    try? await send(type: SpiceMsg.DisplayClient.streamReport.rawValue, payload: report)
                }

            case .streamDataSized:
                let d = try SpiceMsgStreamDataSized.parse(payload)
                if let report = blitStreamFrame(streamID: d.streamID, data: d.data,
                                                mmTime: d.multiMediaTime, dest: d.dest) {
                    try? await send(type: SpiceMsg.DisplayClient.streamReport.rawValue, payload: report)
                }

            case .streamActivateReport:
                let a = try SpiceMsgStreamActivateReport.parse(payload)
                lock.lock()
                reportWindows[a.streamID] = ReportWindow(uniqueID: a.uniqueID,
                                                         maxWindowSize: max(1, a.maxWindowSize),
                                                         timeoutMs: a.timeoutMs)
                lock.unlock()

            case .streamDestroy:
                let d = try SpiceMsgStreamDestroy.parse(payload)
                lock.lock(); streams[d.streamID] = nil; reportWindows[d.streamID] = nil; lock.unlock()
                h264Decoders[d.streamID] = nil

            case .streamDestroyAll:
                lock.lock(); streams.removeAll(); reportWindows.removeAll(); lock.unlock()
                h264Decoders.removeAll()

            case .drawFill:
                let fill = try SpiceDrawFill.parse(payload)
                guard let color = fill.solidColor else { return }
                lock.lock()
                stats.drawOps += 1
                if let surface = surfaces[fill.base.surfaceID] {
                    surface.fill(rect: fill.base.box, color: color)
                    if fill.base.surfaceID == primaryID { markDirtyLocked() }
                }
                lock.unlock()

            // DRAW_OPAQUE shares DRAW_COPY's leading layout (base, src_bitmap,
            // src_area); its extra brush/rop govern compositing we don't model,
            // so we treat it as a straight image copy — enough to get the pixels
            // on screen.
            case .drawCopy, .drawOpaque:
                let copy = try SpiceDrawCopy.parse(payload)
                guard let image = copy.image else { return }
                // Decode outside the lock (the decoder is only touched here).
                let decoded = decoder.decode(image)
                lock.lock()
                stats.drawOps += 1
                if let decoded, let surface = surfaces[copy.base.surfaceID] {
                    surface.blit(src: decoded.pixels, srcWidth: decoded.width, srcHeight: decoded.height,
                                 srcArea: copy.srcArea, dest: copy.base.box)
                    if copy.base.surfaceID == primaryID { markDirtyLocked() }
                }
                lock.unlock()

            case .copyBits:
                let cb = try SpiceCopyBits.parse(payload)
                lock.lock()
                stats.drawOps += 1
                if let surface = surfaces[cb.base.surfaceID] {
                    surface.copyBits(srcX: Int(cb.srcX), srcY: Int(cb.srcY), dest: cb.base.box)
                    if cb.base.surfaceID == primaryID { markDirtyLocked() }
                }
                lock.unlock()

            case .invalList:
                let inval = try SpiceMsgInvalList.parse(payload)
                decoder.invalidate(ids: inval.ids)

            case .invalAllPixmaps:
                decoder.invalidateAllImages()

            case .invalPalette, .invalAllPalettes:
                break   // we don't cache palettes

            default:
                logUnhandled(type: type, name: String(describing: msg))
            }
        } catch {
            log.debug("display message \(type) parse failed: \(String(describing: error), privacy: .public)")
        }
    }

    // Log each unhandled display op once, so missing operations are visible at
    // runtime without flooding the log. Guarded by `lock`.
    private var loggedUnhandled: Set<UInt16> = []
    private func logUnhandled(type: UInt16, name: String) {
        lock.lock(); let isNew = loggedUnhandled.insert(type).inserted; lock.unlock()
        if isNew {
            log.notice("SPICE display op not implemented: type=\(type) (\(name, privacy: .public))")
        }
    }
}
