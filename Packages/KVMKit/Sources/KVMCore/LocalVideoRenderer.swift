import AppKit
import CoreVideo
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "local-renderer")

/// Renders a locally-decoded video source (VNC) into a view, with no WebRTC
/// pipeline. Frames are composited by CoreAnimation via a layer whose contents
/// is each frame's IOSurface, which vsyncs cleanly without a video codec.
///
/// The backend owns this and exposes it as `videoRenderer`; the App embeds
/// `view`. Extracted from the App's former direct-render path so `KVMCore`
/// stays UI-technology-agnostic and the App never touches the frame plumbing.
@MainActor
public final class LocalVideoRenderer: KVMVideoRenderer {
    public var view: NSView { hostView }
    public var onVideoSizeChanged: ((CGSize) -> Void)?

    private let source: LocalVideoOutput
    private let hostView = FlippedLayerView()
    private let frameLayer = CALayer()
    /// Retains the most recent pixel buffers so their pooled IOSurfaces aren't
    /// recycled while CoreAnimation is still scanning them out (would tear).
    private var retainedBuffers: [CVPixelBuffer] = []
    private var videoSize: CGSize = .zero

    public init(source: LocalVideoOutput) {
        self.source = source

        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = NSColor.black.cgColor
        frameLayer.contentsGravity = .resizeAspect      // letterbox like the RTC view
        frameLayer.backgroundColor = NSColor.black.cgColor
        hostView.layer?.addSublayer(frameLayer)
        hostView.onLayout = { [weak self] bounds, scale in
            self?.frameLayer.frame = bounds
            if let scale { self?.frameLayer.contentsScale = scale }
        }

        source.onFrame = { [weak self] frame in
            // Producer runs off the main actor; hop to main for the (cheap)
            // layer update.
            DispatchQueue.main.async { self?.present(frame) }
        }
    }

    public func detach() {
        source.onFrame = nil
        retainedBuffers.removeAll()
    }

    /// Show one decoded frame: point the layer at its IOSurface and refresh the
    /// tracked source size. Runs on the main thread.
    private func present(_ frame: LocalVideoFrame) {
        guard let surface = CVPixelBufferGetIOSurface(frame.pixelBuffer)?.takeUnretainedValue()
        else { return }
        // Keep this and the previous buffers alive so the pool can't overwrite
        // an IOSurface still on screen; drop older ones.
        retainedBuffers.append(frame.pixelBuffer)
        if retainedBuffers.count > 3 { retainedBuffers.removeFirst(retainedBuffers.count - 3) }

        // Assigning identical geometry each frame shouldn't animate.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contents = surface
        CATransaction.commit()

        let size = CGSize(width: frame.width, height: frame.height)
        if size != videoSize {
            videoSize = size
            onVideoSizeChanged?(size)
        }
    }
}

/// Flipped, layer-backed NSView that reports layout changes. Flipped to match
/// the host coordinate system (top-left origin) the layer geometry was built
/// against.
private final class FlippedLayerView: NSView {
    var onLayout: ((CGRect, CGFloat?) -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        onLayout?(bounds, window?.backingScaleFactor)
    }
}
