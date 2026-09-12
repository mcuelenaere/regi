import AppKit
import CoreImage
import Foundation
import ProbeKit

/// Builds a `TelemetryFrame` from the ring and renders it as a QR image.
///
/// The frame advances only when its content changes, and each rendered code is
/// held for a dwell interval so the video encoder settles and the driver's
/// capture lands on a complete symbol. Step 0 measured the driver reading at
/// ~57 ms against a 120 ms dwell, catching every frame.
@MainActor
final class TelemetryRenderer {
    /// Minimum time a code stays on screen. Below ~4 video frames the encoder
    /// has not settled and decode rate drops.
    static let dwell: TimeInterval = 0.12

    /// Error-correction level. H is the strongest, and the step 0 spike showed
    /// we can afford it: 1,273 bytes still holds 130-190 events at measured
    /// density, above the largest catalogue scenario.
    static let correctionLevel = "H"

    private let ring: ProbeEventRing
    private let ciContext = CIContext()
    private var frameIndex: UInt32 = 0
    private var lastPayload: Data?

    /// Bumped on relaunch so a driver can tell the sequence restarted mid-run
    /// and fail rather than splice two incompatible records.
    let epoch: UInt32 = UInt32.random(in: 1...UInt32.max)

    private(set) var lastFrame: TelemetryFrame?
    private(set) var lastEncodedBytes = 0
    private(set) var lastModulesAcross = 0

    init(ring: ProbeEventRing) { self.ring = ring }

    struct Rendered {
        let image: NSImage
        let modulesAcross: Int
        let byteCount: Int
        let eventCount: Int
    }

    func render(health: TelemetryFrame.Health, sidePoints: CGFloat) -> Rendered? {
        // Ask for more than the budget allows; encodeCapped trims to fit, which
        // is what keeps the symbol at a fixed version. Letting it grow instead
        // would shrink the modules and break decoding with no error anywhere.
        let (events, oldestSeq, _) = ring.recent(400)

        // From the cumulative tracker, so the counters the driver reads
        // describe the whole run rather than whatever still fits in the
        // window. Replaying over the window invented `upWithoutDown`s as soon
        // as a press aged out ahead of its release.
        let live = ring.liveState()
        let counters = live.counters

        let screen = NSScreen.main.map { s in
            TelemetryFrame.ScreenInfo(
                originX: Int32(s.frame.origin.x), originY: Int32(s.frame.origin.y),
                width: UInt32(s.frame.width), height: UInt32(s.frame.height),
                backingScale: Float(s.backingScaleFactor))
        }

        let candidate = TelemetryFrame(
            epoch: epoch,
            frameIndex: frameIndex &+ 1,
            probeMonotonicNanos: MachClock.continuousNanos(),
            oldestSeqInWindow: oldestSeq,
            health: health,
            counters: counters,
            heldKeys: live.heldKeys.keys.sorted(),
            screen: screen,
            events: events
        )

        guard let (data, encoded) = try? FrameCodec.encodeCapped(candidate) else { return nil }

        // Hold the current code when nothing changed: a stable symbol is easier
        // for the encoder and lets the driver skip re-reads by frameIndex.
        if let last = lastPayload, last.dropFirst(9) == data.dropFirst(9), lastFrame != nil {
            return nil
        }
        frameIndex &+= 1
        lastPayload = data
        lastFrame = encoded
        lastEncodedBytes = data.count

        guard let gen = makeQR(data) else { return nil }
        lastModulesAcross = gen.modules
        return Rendered(image: gen.image, modulesAcross: gen.modules,
                        byteCount: data.count, eventCount: encoded.events.count)
    }

    private func makeQR(_ payload: Data) -> (image: NSImage, modules: Int)? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(payload, forKey: "inputMessage")
        filter.setValue(Self.correctionLevel, forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else { return nil }
        let modules = Int(out.extent.width.rounded())
        // Nearest-neighbour only: interpolation softens module edges and is a
        // real cause of marginal decodes.
        let scale = 8.0
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return (NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width,
                                                  height: scaled.extent.height)),
                modules)
    }
}
