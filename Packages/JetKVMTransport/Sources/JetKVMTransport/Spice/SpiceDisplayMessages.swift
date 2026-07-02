import Foundation

/// Display-channel message parsers (structs from spice.proto). SPICE uses
/// byte-packed, little-endian structs; pointer fields (`Image *`) are u32
/// offsets from the start of the message body (0 = NULL), so parsing a
/// draw op means reading the fixed part then seeking to the referenced
/// image within the same payload.

/// `struct Rect { int32 top, left, bottom, right }`.
struct SpiceRect: Equatable {
    var top: Int32, left: Int32, bottom: Int32, right: Int32
    var width: Int { Int(right - left) }
    var height: Int { Int(bottom - top) }

    static func read(_ r: inout SpiceByteReader) throws -> SpiceRect {
        SpiceRect(top: try r.readI32(), left: try r.readI32(),
                  bottom: try r.readI32(), right: try r.readI32())
    }
}

/// `SpiceMsgSurfaceCreate` (display SURFACE_CREATE, opcode 314).
struct SpiceMsgSurfaceCreate: Equatable {
    var surfaceID: UInt32
    var width: UInt32
    var height: UInt32
    var format: UInt32     // surface_fmt: 32 = xRGB, 96 = ARGB, ...
    var flags: UInt32      // surface_flags: bit0 = PRIMARY

    var isPrimary: Bool { flags & 1 != 0 }

    static func parse(_ data: Data) throws -> SpiceMsgSurfaceCreate {
        var r = SpiceByteReader(data)
        return SpiceMsgSurfaceCreate(surfaceID: try r.readU32(), width: try r.readU32(),
                                     height: try r.readU32(), format: try r.readU32(),
                                     flags: try r.readU32())
    }
}

/// `SpiceMsgSurfaceDestroy` (opcode 315).
struct SpiceMsgSurfaceDestroy: Equatable {
    var surfaceID: UInt32
    static func parse(_ data: Data) throws -> SpiceMsgSurfaceDestroy {
        var r = SpiceByteReader(data)
        return SpiceMsgSurfaceDestroy(surfaceID: try r.readU32())
    }
}

/// `SpiceMsgDisplayBase` — the prefix of every draw op: target surface, the
/// destination box, and a clip (which we read past; v1 ignores clipping).
struct SpiceDisplayBase: Equatable {
    var surfaceID: UInt32
    var box: SpiceRect

    /// Reads base + clip, leaving `r` positioned at the op-specific data.
    static func read(_ r: inout SpiceByteReader) throws -> SpiceDisplayBase {
        let surfaceID = try r.readU32()
        let box = try SpiceRect.read(&r)
        // Clip: type u8; RECTS(1) carries a u32 pointer we skip.
        let clipType = try r.readU8()
        if clipType == 1 { _ = try r.readU32() }   // @to_ptr offset
        return SpiceDisplayBase(surfaceID: surfaceID, box: box)
    }
}

/// A parsed `struct Image` (descriptor + encoded payload).
struct SpiceImage {
    var type: SpiceMsg.ImageType
    /// Image cache id (from the descriptor). Servers cache images the client
    /// has decoded and later reference them via FROM_CACHE.
    var id: UInt64
    /// Descriptor CACHE_ME flag — the client should keep this decoded image.
    var cacheMe: Bool
    var width: UInt32
    var height: UInt32
    /// The encoded bytes for compressed types (QUIC/LZ/GLZ/JPEG), the raw
    /// pixels for BITMAP, else empty.
    var payload: [UInt8]
    /// For BITMAP: the source pixel format + stride.
    var bitmap: BitmapInfo?

    struct BitmapInfo: Equatable {
        var format: UInt8   // bitmap_fmt: 8=32BIT(xRGB), 9=RGBA, 7=24BIT, 6=16BIT
        var flags: UInt8    // bit2 = TOP_DOWN
        var stride: UInt32
        var topDown: Bool { flags & 0x04 != 0 }
    }

    /// Parse the Image located at absolute `offset` within `payload` (the
    /// message body). Returns nil for NULL (offset 0) or unsupported types.
    static func parse(payloadData: Data, at offset: Int) throws -> SpiceImage? {
        guard offset > 0 else { return nil }
        var r = SpiceByteReader(payloadData)
        try r.seek(to: offset)
        // ImageDescriptor: id u64, type u8, flags u8, width u32, height u32.
        let id = try r.readU64()
        let rawType = try r.readU8()
        let imgFlags = try r.readU8()
        let width = try r.readU32()
        let height = try r.readU32()
        guard let type = SpiceMsg.ImageType(rawValue: rawType) else { return nil }
        let cacheMe = imgFlags & 0x01 != 0     // SPICE_IMAGE_FLAGS_CACHE_ME

        switch type {
        case .quic, .lzRgb, .glzRgb, .jpeg, .lz4:
            // BinaryData { data_size u32, data[data_size] }.
            let size = try r.readU32()
            let bytes = try r.readBytes(Int(size))
            return SpiceImage(type: type, id: id, cacheMe: cacheMe,
                              width: width, height: height, payload: bytes, bitmap: nil)
        case .fromCache, .fromCacheLossless:
            // No data — references a previously-cached image by descriptor id.
            return SpiceImage(type: .fromCache, id: id, cacheMe: false,
                              width: width, height: height, payload: [], bitmap: nil)
        case .bitmap:
            // BitmapData { format u8, flags u8, x u32, y u32, stride u32,
            //              pal(switch), data[stride*y] }.
            let format = try r.readU8()
            let flags = try r.readU8()
            let x = try r.readU32()
            let y = try r.readU32()
            let stride = try r.readU32()
            if flags & 0x02 != 0 {         // PAL_FROM_CACHE
                _ = try r.readU64()
            } else {
                _ = try r.readU32()        // Palette* offset (unused in v1)
            }
            let bytes = try r.readBytes(Int(stride) * Int(y))
            return SpiceImage(type: type, id: id, cacheMe: cacheMe, width: x, height: y,
                              payload: bytes,
                              bitmap: BitmapInfo(format: format, flags: flags, stride: stride))
        default:
            return nil   // LZ_PLT / ZLIB_GLZ / JPEG_ALPHA / SURFACE / caches: v1 skips
        }
    }
}

/// A parsed DRAW_COPY (opcode 304): where to draw and the source image.
struct SpiceDrawCopy {
    var base: SpiceDisplayBase
    var srcArea: SpiceRect
    var image: SpiceImage?

    static func parse(_ data: Data) throws -> SpiceDrawCopy {
        var r = SpiceByteReader(data)
        let base = try SpiceDisplayBase.read(&r)
        let srcBitmapOffset = try r.readU32()      // Image *src_bitmap
        let srcArea = try SpiceRect.read(&r)
        _ = try r.readU16()                        // rop_descriptor
        _ = try r.readU8()                         // scale_mode
        // QMask: flags u8, pos (2×i32), bitmap ptr u32 — skipped in v1.
        _ = try r.readU8(); _ = try r.readI32(); _ = try r.readI32(); _ = try r.readU32()
        let image = try SpiceImage.parse(payloadData: data, at: Int(srcBitmapOffset))
        return SpiceDrawCopy(base: base, srcArea: srcArea, image: image)
    }
}

/// A parsed DRAW_FILL (opcode 302). v1 supports solid-color brushes only.
struct SpiceDrawFill {
    var base: SpiceDisplayBase
    /// Solid fill color (0x00RRGGBB), or nil for unsupported pattern brushes.
    var solidColor: UInt32?

    static func parse(_ data: Data) throws -> SpiceDrawFill {
        var r = SpiceByteReader(data)
        let base = try SpiceDisplayBase.read(&r)
        let brushType = try r.readU8()             // brush_type: SOLID=1, PATTERN=2
        var color: UInt32?
        if brushType == 1 { color = try r.readU32() }
        return SpiceDrawFill(base: base, solidColor: color)
    }
}
