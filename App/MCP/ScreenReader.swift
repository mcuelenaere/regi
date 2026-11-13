// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import KVMKit
import UniformTypeIdentifiers
import Vision

/// The remote display as pixels and as text: frames out of a session's video,
/// on-device OCR, and the thumbnails `waitStable` compares.
@MainActor
enum ScreenReader {
    struct Line: Sendable {
        let text: String
        /// Framebuffer pixels, top-left origin.
        let box: CGRect
        let confidence: Float
    }

    private static let ciContext = CIContext()

    static func size(of session: Session) -> (width: Int, height: Int)? {
        guard let buffer = session.videoRenderer?.latestFrame() else { return nil }
        return (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
    }

    /// The latest frame, copied out of the decoder's buffer, cropped to
    /// `region` (framebuffer pixels, top-left origin) and then scaled.
    static func frame(of session: Session, region: CGRect? = nil, scale: Double = 1) -> CGImage? {
        guard let buffer = session.videoRenderer?.latestFrame() else { return nil }
        var image = CIImage(cvPixelBuffer: buffer)
        if let region {
            // Core Image counts y from the bottom.
            image = image.cropped(to: CGRect(x: region.minX, y: image.extent.height - region.maxY,
                                             width: region.width, height: region.height))
        }
        if scale < 1 {
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = image
            filter.scale = Float(scale)
            image = filter.outputImage ?? image
        }
        return ciContext.createCGImage(image, from: image.extent.integral, format: .RGBA8,
                                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// The frame shrunk to `width` pixels across, as RGBA bytes: enough to
    /// tell whether the screen changed, cheap enough to take ten times a second.
    static func thumbnail(of session: Session, width: Int = 96) -> [UInt8]? {
        guard let buffer = session.videoRenderer?.latestFrame() else { return nil }
        let source = CIImage(cvPixelBuffer: buffer)
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = source
        filter.scale = Float(CGFloat(width) / source.extent.width)
        guard let scaled = filter.outputImage else { return nil }
        let height = max(1, Int(scaled.extent.height.rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        ciContext.render(scaled, toBitmap: &pixels, rowBytes: width * 4,
                         bounds: CGRect(x: scaled.extent.minX, y: scaled.extent.minY, width: CGFloat(width), height: CGFloat(height)),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return pixels
    }

    /// Mean absolute difference per colour byte, 0–255; frames of different
    /// sizes differ completely.
    nonisolated static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var total = 0
        for index in stride(from: 0, to: a.count, by: 4) {
            total += abs(Int(a[index]) - Int(b[index])) + abs(Int(a[index + 1]) - Int(b[index + 1]))
                + abs(Int(a[index + 2]) - Int(b[index + 2]))
        }
        return Double(total) / Double(a.count / 4 * 3)
    }

    /// Two Vision passes, merged. `.accurate` reads text far better, but on a
    /// synthetic dialog it missed a white-on-blue "OK" button that `.fast`
    /// found, and buttons are what scripts look for. A box that mostly
    /// repeats one already kept is dropped: accurate before fast, larger
    /// before smaller.
    nonisolated static func recognizeText(in image: CGImage) throws -> [Line] {
        let byArea = { (lines: [Line]) in lines.sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height } }
        var kept: [Line] = []
        for line in byArea(try recognize(image, level: .accurate)) + byArea(try recognize(image, level: .fast))
        where !kept.contains(where: { overlaps($0.box, line.box) }) {
            kept.append(line)
        }
        return kept.sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }
    }

    nonisolated private static func recognize(_ image: CGImage, level: VNRequestTextRecognitionLevel) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        // Screens are full of hostnames, paths and codes a dictionary "fixes".
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let b = observation.boundingBox  // normalized, bottom-left origin
            return Line(text: candidate.string,
                        box: CGRect(x: b.minX * width, y: (1 - b.maxY) * height,
                                    width: b.width * width, height: b.height * height),
                        confidence: candidate.confidence)
        }
    }

    /// Same text seen by both passes: most of the smaller box is shared.
    nonisolated private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = a.intersection(b)
        guard !shared.isNull else { return false }
        return shared.width * shared.height >= 0.5 * min(a.width * a.height, b.width * b.height)
    }

    nonisolated static func encode(_ image: CGImage, png: Bool) -> Data? {
        let data = NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
