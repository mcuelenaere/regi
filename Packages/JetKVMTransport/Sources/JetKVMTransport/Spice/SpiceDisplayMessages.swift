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
        // Clip: type u8; RECTS(1) carries an INLINE ClipRects — num_rects
        // (u32) followed by that many 16-byte Rects — not a pointer.
        let clipType = try r.readU8()
        if clipType == 1 {
            let numRects = try r.readU32()
            try r.skip(Int(numRects) * 16)
        }
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
    /// Raw src_bitmap offset (0 = NULL) — kept for diagnostics.
    var srcBitmapOffset: UInt32

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
        return SpiceDrawCopy(base: base, srcArea: srcArea, image: image,
                             srcBitmapOffset: srcBitmapOffset)
    }
}

/// STREAM_CREATE (122): a server-side video stream over a surface region.
struct SpiceMsgStreamCreate {
    var streamID: UInt32
    var codec: SpiceProtocol.VideoCodec?
    var dest: SpiceRect

    static func parse(_ data: Data) throws -> SpiceMsgStreamCreate {
        var r = SpiceByteReader(data)
        _ = try r.readU32()               // surface_id
        let id = try r.readU32()
        _ = try r.readU8()                // stream_flags
        let codecRaw = try r.readU8()     // video_codec_type
        _ = try r.readU64()               // stamp
        _ = try r.readU32(); _ = try r.readU32()   // stream_width, stream_height
        _ = try r.readU32(); _ = try r.readU32()   // src_width, src_height
        let dest = try SpiceRect.read(&r)
        // clip ignored (v1)
        return SpiceMsgStreamCreate(streamID: id,
                                    codec: SpiceProtocol.VideoCodec(rawValue: codecRaw),
                                    dest: dest)
    }
}

/// STREAM_DATA (123): one encoded frame for a stream.
struct SpiceMsgStreamData {
    var streamID: UInt32
    /// Server multimedia timestamp (ms) — feeds the stream-report window.
    var multiMediaTime: UInt32
    var data: [UInt8]

    static func parse(_ data: Data) throws -> SpiceMsgStreamData {
        var r = SpiceByteReader(data)
        let id = try r.readU32()
        let mmTime = try r.readU32()      // multi_media_time
        let size = try r.readU32()
        return SpiceMsgStreamData(streamID: id, multiMediaTime: mmTime, data: try r.readBytes(Int(size)))
    }
}

/// STREAM_DATA_SIZED (316): a frame that also carries a (possibly changed)
/// destination rect.
struct SpiceMsgStreamDataSized {
    var streamID: UInt32
    var multiMediaTime: UInt32
    var dest: SpiceRect
    var data: [UInt8]

    static func parse(_ data: Data) throws -> SpiceMsgStreamDataSized {
        var r = SpiceByteReader(data)
        let id = try r.readU32()
        let mmTime = try r.readU32()      // multi_media_time
        _ = try r.readU32(); _ = try r.readU32()   // width, height
        let dest = try SpiceRect.read(&r)
        let size = try r.readU32()
        return SpiceMsgStreamDataSized(streamID: id, multiMediaTime: mmTime, dest: dest,
                                       data: try r.readBytes(Int(size)))
    }
}

/// STREAM_ACTIVATE_REPORT (319): the server asks the client to start sending
/// periodic STREAM_REPORT feedback for a stream. `maxWindowSize` (frames) and
/// `timeoutMs` bound how often a report is due; the server uses those reports
/// for adaptive rate control, so a client that advertises the STREAM_REPORT
/// cap but never reports gets throttled to the minimum bitrate.
struct SpiceMsgStreamActivateReport {
    var streamID: UInt32
    var uniqueID: UInt32
    var maxWindowSize: UInt32
    var timeoutMs: UInt32

    static func parse(_ data: Data) throws -> SpiceMsgStreamActivateReport {
        var r = SpiceByteReader(data)
        return SpiceMsgStreamActivateReport(streamID: try r.readU32(), uniqueID: try r.readU32(),
                                            maxWindowSize: try r.readU32(), timeoutMs: try r.readU32())
    }
}

/// STREAM_DESTROY (125).
struct SpiceMsgStreamDestroy {
    var streamID: UInt32
    static func parse(_ data: Data) throws -> SpiceMsgStreamDestroy {
        var r = SpiceByteReader(data)
        return SpiceMsgStreamDestroy(streamID: try r.readU32())
    }
}

/// COPY_BITS (104): copy a `base.box`-sized block from `src` to `base.box`
/// within the same surface. Used for scrolling and window drags.
struct SpiceCopyBits {
    var base: SpiceDisplayBase
    var srcX: Int32
    var srcY: Int32

    static func parse(_ data: Data) throws -> SpiceCopyBits {
        var r = SpiceByteReader(data)
        let base = try SpiceDisplayBase.read(&r)
        return SpiceCopyBits(base: base, srcX: try r.readI32(), srcY: try r.readI32())
    }
}

/// INVAL_LIST (105): image-cache entries the server has dropped and will no
/// longer reference via FROM_CACHE. Body: count u16, then `count` ResourceIDs
/// (type u8 + id u64, byte-packed). We invalidate every id from our image
/// cache regardless of type (we only cache pixmaps).
struct SpiceMsgInvalList {
    var ids: [UInt64]

    static func parse(_ data: Data) throws -> SpiceMsgInvalList {
        var r = SpiceByteReader(data)
        let count = try r.readU16()
        var ids: [UInt64] = []
        ids.reserveCapacity(Int(count))
        for _ in 0..<count {
            _ = try r.readU8()            // ResourceID.type
            ids.append(try r.readU64())   // ResourceID.id
        }
        return SpiceMsgInvalList(ids: ids)
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
