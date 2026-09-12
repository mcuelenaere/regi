import AppKit
import CoreImage
import Foundation
import ProbeKit
import ScreenCaptureKit
import Vision

/// Reads the probe's QR telemetry out of Regi's window.
///
/// This is the whole return path: the target renders a QR band, it travels over
/// HDMI into the KVM and back as video, Regi draws it, and we capture Regi's
/// window and decode. There is deliberately no network connection to the target.
public final class VideoReader {
    public enum ReadError: Error, CustomStringConvertible {
        case noMatchingWindow(String)
        case captureFailed(String)
        case noQRFound
        case undecodableQR(String)
        case payloadUnavailable
        case frameDecodeFailed(String)

        public var description: String {
            switch self {
            case .noMatchingWindow(let n):
                return """
                no on-screen window belonging to an application named "\(n)".
                  - is Regi running and showing the target?
                  - Screen Recording must be granted to whatever runs this binary
                    (SCShareableContent returns a short list rather than an error)
                Matching is by owning application, never by window title: a
                browser tab whose title merely contains the name would otherwise
                be captured instead.
                """
            case .captureFailed(let m):   return "window capture failed: \(m)"
            case .noQRFound:
                return """
                captured the window but found no QR code.
                  - has 'Start run' been pressed on the target? the band only
                    renders while a run is active
                  - is the probe's run window visible and unobscured?
                """
            case .undecodableQR(let m):   return "QR found but not decodable: \(m)"
            case .payloadUnavailable:     return "QR decoded but no binary payload accessor worked"
            case .frameDecodeFailed(let m): return "telemetry decode failed: \(m)"
            }
        }
    }

    private let windowName: String

    /// Where the video sits inside the window, in window points, if known.
    ///
    /// Vision downsamples a large image before looking for barcodes, so
    /// handing it a 3360x2100 window screenshot with a QR occupying a corner
    /// can push the symbol below what it can resolve — enlarging the window
    /// made decoding *worse*, not better. Cropping to the video first keeps
    /// the symbol's share of the pixels high.
    public var videoRectInWindow: CGRect?

    public init(windowName: String) {
        self.windowName = windowName
        // A bare CLI has no window-server connection, and touching AppKit or
        // CoreGraphics without one trips CGS_REQUIRE_INIT. `.prohibited` gives
        // us the connection while staying invisible, so it cannot steal focus
        // from Regi -- which matters, because Regi must stay frontmost.
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    public struct Capture {
        public let frame: TelemetryFrame
        public let qrPixelWidth: CGFloat
        public let capturePixelWidth: CGFloat
        public let millis: Double
        /// Captured pixels per QR module, as a **lower bound**.
        ///
        /// The frame does not carry its symbol size, so this assumes the
        /// largest we ever emit (version 40 = 177 modules plus a 1-module quiet
        /// zone each side). A smaller payload produces a smaller symbol and
        /// therefore *more* pixels per module, so the real figure is at least
        /// this. Erring low is the right direction for a health check.
        ///
        /// Below ~4 the decode rate collapses; at 3 Vision stops locating the
        /// symbol at all. Both measured in step 0.
        public var pixelsPerModule: CGFloat? {
            qrPixelWidth > 0 ? qrPixelWidth / 179.0 : nil
        }
    }

    /// Finds the window by **owning application**, never by title.
    ///
    /// Matching titles was a real trap: a browser tab called
    /// "…mcuelenaere/regi" matched `--window=Regi` and the harness captured
    /// that instead, failing every scenario with "no QR code". Window titles
    /// are arbitrary text controlled by whatever the user happens to have
    /// open; the owning application is not.
    ///
    /// Among that app's windows the largest wins, which distinguishes a
    /// session window from the Hosts list.
    public func findWindow() async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let needle = windowName.lowercased()

        let byApp = content.windows.filter { w in
            guard w.frame.width > 200, w.frame.height > 200 else { return false }
            return (w.owningApplication?.applicationName ?? "").lowercased() == needle
        }
        if let best = byApp.max(by: { $0.frame.width * $0.frame.height
                                    < $1.frame.width * $1.frame.height }) {
            return best
        }

        // Fall back to a partial application-name match, still never a title.
        let partial = content.windows.filter { w in
            guard w.frame.width > 200, w.frame.height > 200 else { return false }
            return (w.owningApplication?.applicationName ?? "").lowercased().contains(needle)
        }
        if let best = partial.max(by: { $0.frame.width * $0.frame.height
                                      < $1.frame.width * $1.frame.height }) {
            return best
        }
        throw ReadError.noMatchingWindow(windowName)
    }

    public func read(from window: SCWindow) async throws -> Capture {
        let start = Date()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Capture at backing resolution: downscaling here would measure our own
        // resampling rather than the video path.
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.captureResolution = .best
        config.showsCursor = false

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                               configuration: config)
        } catch {
            throw ReadError.captureFailed(error.localizedDescription)
        }

        // Crop to the video before detection when we know where it is.
        var searchImage = image
        if let rect = videoRectInWindow, window.frame.width > 0 {
            let sx = CGFloat(image.width) / window.frame.width
            let sy = CGFloat(image.height) / window.frame.height
            let crop = CGRect(x: rect.minX * sx, y: rect.minY * sy,
                              width: rect.width * sx, height: rect.height * sy)
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if crop.width > 100, crop.height > 100, let cropped = image.cropping(to: crop) {
                searchImage = cropped
            }
        }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cgImage: searchImage, options: [:]).perform([request])
        } catch {
            throw ReadError.undecodableQR(error.localizedDescription)
        }
        guard let obs = request.results?.first else { throw ReadError.noQRFound }

        guard #available(macOS 15.0, *), let raw = obs.payloadData else {
            throw ReadError.payloadUnavailable
        }
        // payloadData is the raw QR bit stream -- mode indicator and
        // character-count header attached -- not the payload.
        guard let payload = QRBitstream.bytePayload(from: raw) else {
            throw ReadError.payloadUnavailable
        }

        do {
            let frame = try FrameCodec.decode(payload)
            return Capture(frame: frame,
                           qrPixelWidth: obs.boundingBox.width * CGFloat(searchImage.width),
                           capturePixelWidth: CGFloat(searchImage.width),
                           millis: Date().timeIntervalSince(start) * 1000)
        } catch {
            throw ReadError.frameDecodeFailed("\(error)")
        }
    }
}
