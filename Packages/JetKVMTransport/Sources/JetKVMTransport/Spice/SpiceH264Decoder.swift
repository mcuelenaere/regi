import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "spice-h264")

/// Hardware H.264 decoder for SPICE video streams, via VideoToolbox.
///
/// SPICE/gstreamer sends an Annex-B byte-stream (NAL units separated by
/// `00 00 01` / `00 00 00 01` start codes). We split it, pull the SPS/PPS to
/// build a `CMVideoFormatDescription`, wrap the slice NALs as AVCC
/// (length-prefixed) sample buffers, and decode to a `CVPixelBuffer`. The
/// session is configured to output `32BGRA` so frames drop straight into the
/// display surface's BGRA blit — no colour conversion.
///
/// One instance per stream; used serially from the display read loop.
final class SpiceH264Decoder {
    private var session: VTDecompressionSession?
    private var formatDesc: CMFormatDescription?
    private var sps: [UInt8] = []
    private var pps: [UInt8] = []

    deinit { invalidate() }

    private func invalidate() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    /// Decode one stream frame (Annex-B). Returns BGRA pixels, or nil if the
    /// frame can't be decoded yet (e.g. no SPS/PPS seen).
    func decode(_ annexB: [UInt8]) -> SpiceImageDecoder.Decoded? {
        var vcl: [[UInt8]] = []
        var paramsChanged = false
        for nal in Self.nalUnits(annexB) {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7: if nal != sps { sps = nal; paramsChanged = true }   // SPS
            case 8: if nal != pps { pps = nal; paramsChanged = true }   // PPS
            case 1, 5: vcl.append(nal)                                  // slice (non-IDR / IDR)
            default: break                                              // SEI/AUD/etc.
            }
        }
        if paramsChanged || session == nil { rebuildSession() }
        guard let session, let formatDesc, !vcl.isEmpty,
              let sample = Self.sampleBuffer(vcl: vcl, formatDesc: formatDesc) else { return nil }

        var decoded: CVImageBuffer?
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { st, _, image, _, _ in
            if st == noErr { decoded = image }
        }
        guard status == noErr else { return nil }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard let pixelBuffer = decoded else { return nil }
        return Self.bgra(from: pixelBuffer)
    }

    private func rebuildSession() {
        guard !sps.isEmpty, !pps.isEmpty else { return }
        invalidate()
        formatDesc = nil

        var fmt: CMFormatDescription?
        let created: OSStatus = sps.withUnsafeBufferPointer { spsBuf in
            pps.withUnsafeBufferPointer { ppsBuf in
                let pointers = [spsBuf.baseAddress!, ppsBuf.baseAddress!]
                let sizes = [spsBuf.count, ppsBuf.count]
                return pointers.withUnsafeBufferPointer { pp in
                    sizes.withUnsafeBufferPointer { ss in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pp.baseAddress!,
                            parameterSetSizes: ss.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &fmt)
                    }
                }
            }
        }
        guard created == noErr, let fmt else {
            log.error("H264 format description failed: \(created)")
            return
        }
        formatDesc = fmt

        let imageAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var newSession: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fmt,
            decoderSpecification: nil,
            imageBufferAttributes: imageAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession)
        if st == noErr {
            session = newSession
        } else {
            log.error("H264 decompression session create failed: \(st)")
        }
    }

    /// Split an Annex-B buffer into NAL units (start codes stripped).
    private static func nalUnits(_ data: [UInt8]) -> [[UInt8]] {
        let n = data.count
        func startCode(at p: Int) -> Int {
            if p + 3 <= n, data[p] == 0, data[p + 1] == 0, data[p + 2] == 1 { return 3 }
            if p + 4 <= n, data[p] == 0, data[p + 1] == 0, data[p + 2] == 0, data[p + 3] == 1 { return 4 }
            return 0
        }
        var nals: [[UInt8]] = []
        var i = 0
        var start = -1
        while i < n {
            let sc = startCode(at: i)
            if sc > 0 {
                if start >= 0, i > start { nals.append(Array(data[start..<i])) }
                i += sc
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < n { nals.append(Array(data[start..<n])) }
        return nals
    }

    /// Wrap slice NALs as an AVCC (4-byte length-prefixed) `CMSampleBuffer`.
    private static func sampleBuffer(vcl: [[UInt8]], formatDesc: CMFormatDescription) -> CMSampleBuffer? {
        var avcc = [UInt8]()
        avcc.reserveCapacity(vcl.reduce(0) { $0 + $1.count + 4 })
        for nal in vcl {
            let len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: len) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: nal)
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block
        ) == noErr, let block,
        CMBlockBufferAssureBlockMemory(block) == noErr else { return nil }

        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var sizes = [avcc.count]
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDesc,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    /// Copy a (BGRA) `CVPixelBuffer` into a tightly-packed BGRA byte array.
    private static func bgra(from pb: CVPixelBuffer) -> SpiceImageDecoder.Decoded? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let srcStride = CVPixelBufferGetBytesPerRow(pb)
        let dstStride = w * 4
        var pixels = [UInt8](repeating: 0, count: dstStride * h)
        pixels.withUnsafeMutableBytes { dst in
            for row in 0..<h {
                memcpy(dst.baseAddress!.advanced(by: row * dstStride),
                       base.advanced(by: row * srcStride), dstStride)
            }
        }
        return SpiceImageDecoder.Decoded(pixels: pixels, width: w, height: h)
    }
}
