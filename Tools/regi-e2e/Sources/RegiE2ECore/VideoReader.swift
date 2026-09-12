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
                no on-screen window matching "\(n)".
                  - is Regi running and showing the target?
                  - Screen Recording must be granted to whatever runs this binary
                    (SCShareableContent returns a short list rather than an error)
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

    public func findWindow() async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let needle = windowName.lowercased()
        let match = content.windows.first { w in
            let title = (w.title ?? "").lowercased()
            let app = (w.owningApplication?.applicationName ?? "").lowercased()
            return (title.contains(needle) || app.contains(needle)) && w.frame.width > 200
        }
        guard let match else { throw ReadError.noMatchingWindow(windowName) }
        return match
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

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
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
                           qrPixelWidth: obs.boundingBox.width * CGFloat(image.width),
                           capturePixelWidth: CGFloat(image.width),
                           millis: Date().timeIntervalSince(start) * 1000)
        } catch {
            throw ReadError.frameDecodeFailed("\(error)")
        }
    }
}
