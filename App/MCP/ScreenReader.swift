// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import ImageIO
import KVMKit
import UniformTypeIdentifiers
import Vision

/// The remote display as pixels, text and controls: frames out of a session's
/// video, on-device OCR, the UI element detector, and the thumbnails
/// `waitStable` compares.
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

    struct Element: Sendable {
        /// Framebuffer pixels, top-left origin.
        let box: CGRect
        let confidence: Float
    }

    /// OmniParser's icon detector (YOLOv8, AGPL-3.0), compiled into the app:
    /// one class, "something you can interact with". Nil if the build lacks it.
    nonisolated(unsafe) private static let detector: VNCoreMLModel? = {
        guard let url = Bundle.main.url(forResource: "UIElementDetector", withExtension: "mlmodelc") else { return nil }
        return try? VNCoreMLModel(for: MLModel(contentsOf: url))
    }()

    /// Controls on screen, text or not: buttons, icons, fields, rows. The
    /// image is letterboxed into the model's square input; confidence and
    /// overlap thresholds are built into the model (Tools/ui-detector).
    nonisolated static func detectElements(in image: CGImage) throws -> [Element]? {
        guard let detector else { return nil }
        let request = VNCoreMLRequest(model: detector)
        request.imageCropAndScaleOption = .scaleFit
        try VNImageRequestHandler(cgImage: image).perform([request])
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return (request.results as? [VNRecognizedObjectObservation] ?? []).map { observation in
            let b = observation.boundingBox  // normalized, bottom-left origin
            return Element(box: CGRect(x: b.minX * width, y: (1 - b.maxY) * height,
                                       width: b.width * width, height: b.height * height),
                           confidence: observation.confidence)
        }
    }

    /// Load the detector and run it once on a blank frame: Core ML compiles
    /// the model for this Mac on first use, about 4 s on a 1080p frame.
    nonisolated static func warmUp() {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let blank = context.makeImage() else { return }
        _ = try? detectElements(in: blank)
    }

    /// Same thing seen twice: most of the smaller box is shared.
    nonisolated static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = a.intersection(b)
        guard !shared.isNull else { return false }
        return shared.width * shared.height >= 0.5 * min(a.width * a.height, b.width * b.height)
    }

    /// `image` with each box outlined and tagged with its index, so whoever
    /// looks at it can name a box by number. Boxes are image pixels, top-left
    /// origin. Tags sit just above a box, inside it when there's no room.
    nonisolated static func mark(_ image: CGImage, boxes: [CGRect]) -> CGImage {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let colours: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal]
        for (index, box) in boxes.enumerated() {
            let colour = colours[index % colours.count]
            let rect = CGRect(x: box.minX, y: CGFloat(height) - box.maxY, width: box.width, height: box.height)
            context.setStrokeColor(colour.cgColor)
            context.setLineWidth(2)
            context.stroke(rect)
            let tag = NSAttributedString(string: "\(index)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white])
            let size = tag.size()
            let above = rect.maxY + size.height + 2 <= CGFloat(height)
            let back = CGRect(x: rect.minX, y: above ? rect.maxY : rect.maxY - size.height - 2,
                              width: size.width + 4, height: size.height + 2)
            context.setFillColor(colour.cgColor)
            context.fill(back)
            tag.draw(at: CGPoint(x: back.minX + 2, y: back.minY + 1))
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage() ?? image
    }

    nonisolated static func encode(_ image: CGImage, png: Bool) -> Data? {
        let data = NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
