import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "vnc-h264")

/// Decoder for the RFB "Open H.264" encoding (50) — the format PiKVM's
/// `kvmd-vnc` and TigerVNC 1.13+ interoperate on. Each rect is `u32 length` +
/// `u32 flags` (bit 0x1 = reset this context, 0x2 = reset all) + `length` bytes
/// of an Annex-B H.264 byte stream. We decode with VideoToolbox into a BGRA
/// pixel buffer and blit it into the framebuffer.
///
/// A single decoder context is maintained (PiKVM/QEMU send one full-frame H.264
/// rect per update); a geometry change or a reset flag rebuilds it. All work
/// runs on the stream engine's decode task (off the main actor), so blocking on
/// the synchronous VideoToolbox decode here is fine.
final class H264Decoder {
    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var contextWidth = 0
    private var contextHeight = 0

    private static let resetContext: UInt32 = 0x1
    private static let resetAllContexts: UInt32 = 0x2
    private static let maxRectBytes = 64 * 1024 * 1024

    func reset() {
        invalidateSession()
        sps = nil
        pps = nil
        contextWidth = 0
        contextHeight = 0
    }

    private func invalidateSession() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDesc = nil
    }

    func decodeRect(
        _ rect: RFBProtocol.RectHeader,
        channel: any VNCByteChannel,
        framebuffer fb: VNCFramebuffer
    ) async throws {
        var header = VNCByteReader(try await channel.readExactly(8))
        let length = Int(try header.readU32())
        let flags = try header.readU32()
        guard length >= 0, length <= Self.maxRectBytes else {
            throw VNCConnectionError.protocolError("H264: implausible length \(length)")
        }
        let payload = length > 0 ? try await channel.readExactly(length) : Data()

        if flags & (Self.resetAllContexts | Self.resetContext) != 0 { reset() }
        if rect.width != contextWidth || rect.height != contextHeight {
            reset()
            contextWidth = rect.width
            contextHeight = rect.height
        }
        guard length > 0 else { return }

        // Split the Annex-B stream; cache parameter sets, collect VCL NALs.
        let nals = Self.nalUnits(in: [UInt8](payload))
        var vcl: [[UInt8]] = []
        var gotNewParams = false
        for nal in nals {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7: sps = Array(nal); gotNewParams = true  // SPS
            case 8: pps = Array(nal); gotNewParams = true  // PPS
            case 1, 5: vcl.append(Array(nal))              // non-IDR / IDR slice
            default: break                                  // SEI, AUD, … — ignore
            }
        }

        if gotNewParams || formatDesc == nil {
            rebuildSession()
        }
        guard let session, !vcl.isEmpty else { return } // can't decode without params/slices

        guard let sampleBuffer = makeSampleBuffer(vcl: vcl) else {
            log.error("H264: failed to build sample buffer")
            return
        }

        // Synchronous decode via the block API + a semaphore (we're off the
        // main actor). A decode failure leaves the framebuffer unchanged
        // (stale) rather than tearing down the stream — the next keyframe
        // recovers.
        var decoded: CVImageBuffer?
        let semaphore = DispatchSemaphore(value: 0)
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: &infoFlags
        ) { status, _, imageBuffer, _, _ in
            if status == noErr { decoded = imageBuffer }
            semaphore.signal()
        }
        if status == noErr {
            // VideoToolbox calls the handler once per request, but guard against
            // a decoder that never does so it can't wedge the stream task.
            if semaphore.wait(timeout: .now() + 2) == .timedOut {
                log.error("H264: decode timed out")
                return
            }
        } else {
            log.error("H264: decode submit failed (\(status))")
            return
        }

        guard let pixelBuffer = decoded else { return }
        try blit(pixelBuffer, into: fb, at: rect)
    }

    private func blit(_ pb: CVPixelBuffer, into fb: VNCFramebuffer, at rect: RFBProtocol.RectHeader) throws {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let w = min(CVPixelBufferGetWidth(pb), rect.width)
        let h = min(CVPixelBufferGetHeight(pb), rect.height)
        guard w > 0, h > 0 else { return }
        let src = UnsafeRawBufferPointer(start: base, count: bpr * CVPixelBufferGetHeight(pb))
        try fb.blitBGRA(x: rect.x, y: rect.y, w: w, h: h, src: src, srcBytesPerRow: bpr)
    }

    // MARK: - VideoToolbox setup

    private func rebuildSession() {
        guard let sps, let pps else { return }
        invalidateSession()

        var format: CMFormatDescription?
        let created = sps.withUnsafeBufferPointer { spsBuf in
            pps.withUnsafeBufferPointer { ppsBuf -> OSStatus in
                let pointers = [spsBuf.baseAddress!, ppsBuf.baseAddress!]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { ptrs in
                    sizes.withUnsafeBufferPointer { szs in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrs.baseAddress!,
                            parameterSetSizes: szs.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format)
                    }
                }
            }
        }
        guard created == noErr, let format else {
            log.error("H264: format description failed (\(created))")
            return
        }
        formatDesc = format

        let destAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: destAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession)
        guard status == noErr else {
            log.error("H264: session create failed (\(status))")
            return
        }
        session = newSession
    }

    private func makeSampleBuffer(vcl: [[UInt8]]) -> CMSampleBuffer? {
        guard let formatDesc else { return nil }
        // Concatenate VCL NALs in AVCC form (4-byte big-endian length prefix).
        var avcc = Data()
        for nal in vcl {
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: nal)
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        status = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    // MARK: - Annex-B parsing

    /// Split an Annex-B byte stream into NAL units (start codes stripped).
    static func nalUnits(in data: [UInt8]) -> [ArraySlice<UInt8>] {
        var units: [ArraySlice<UInt8>] = []
        let n = data.count
        func startCodeLength(at p: Int) -> Int? {
            if p + 4 <= n, data[p] == 0, data[p + 1] == 0, data[p + 2] == 0, data[p + 3] == 1 { return 4 }
            if p + 3 <= n, data[p] == 0, data[p + 1] == 0, data[p + 2] == 1 { return 3 }
            return nil
        }
        var p = 0
        var nalStart = -1
        while p < n {
            if let sc = startCodeLength(at: p) {
                if nalStart >= 0, p > nalStart { units.append(data[nalStart..<p]) }
                p += sc
                nalStart = p
            } else {
                p += 1
            }
        }
        if nalStart >= 0, nalStart < n { units.append(data[nalStart..<n]) }
        return units
    }

    deinit { invalidateSession() }
}
