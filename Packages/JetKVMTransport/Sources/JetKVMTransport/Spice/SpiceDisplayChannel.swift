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
/// v1 handles surface create/destroy, mode, reset, and image copies/fills
/// (QUIC/LZ/GLZ/JPEG/bitmap, with the client image cache). Video streams and
/// the less-common draw ops (stroke/text/rop3/…) are not yet composited.
final class SpiceDisplayChannel: SpiceChannel {
    /// Fired with a fresh copy of the primary surface after each update.
    var onFrame: (@Sendable (SpiceFrame) -> Void)?

    private var surfaces: [UInt32: SpiceSurface] = [:]
    private var primaryID: UInt32?
    private let decoder = SpiceImageDecoder()

    override func start() {
        super.start()
        Task { [weak self] in await self?.sendDisplayInit() }
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
    }

    override func handle(type: UInt16, payload: Data) async {
        guard let msg = SpiceMsg.Display(rawValue: type) else { return }
        do {
            switch msg {
            case .surfaceCreate:
                let s = try SpiceMsgSurfaceCreate.parse(payload)
                surfaces[s.surfaceID] = SpiceSurface(width: Int(s.width), height: Int(s.height))
                if s.isPrimary { primaryID = s.surfaceID }
                log.debug("surface \(s.surfaceID) create \(s.width)x\(s.height) primary=\(s.isPrimary)")

            case .surfaceDestroy:
                let d = try SpiceMsgSurfaceDestroy.parse(payload)
                surfaces[d.surfaceID] = nil
                if primaryID == d.surfaceID { primaryID = nil }

            case .mode:
                // Legacy single-surface path: x_res, y_res, bits. Create a
                // primary surface if the server didn't send SURFACE_CREATE.
                var r = SpiceByteReader(payload)
                let xres = try r.readU32(), yres = try r.readU32()
                if primaryID == nil {
                    surfaces[0] = SpiceSurface(width: Int(xres), height: Int(yres))
                    primaryID = 0
                }

            case .reset:
                surfaces.removeAll()
                primaryID = nil
                decoder.reset()

            case .drawFill:
                let fill = try SpiceDrawFill.parse(payload)
                guard let surface = surfaces[fill.base.surfaceID] else { return }
                if let color = fill.solidColor { surface.fill(rect: fill.base.box, color: color) }
                emitIfPrimary(fill.base.surfaceID)

            case .drawCopy:
                let copy = try SpiceDrawCopy.parse(payload)
                guard let surface = surfaces[copy.base.surfaceID] else { return }
                guard let image = copy.image, let decoded = decoder.decode(image) else { return }
                surface.blit(src: decoded.pixels, srcWidth: decoded.width, srcHeight: decoded.height,
                             srcArea: copy.srcArea, dest: copy.base.box)
                emitIfPrimary(copy.base.surfaceID)

            default:
                break   // streams + uncommon draw ops: v1 skips
            }
        } catch {
            log.debug("display message \(type) parse failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func emitIfPrimary(_ surfaceID: UInt32) {
        guard surfaceID == primaryID, let surface = surfaces[surfaceID], let onFrame else { return }
        onFrame(SpiceFrame(width: surface.width, height: surface.height, bgra: surface.pixels))
    }
}
