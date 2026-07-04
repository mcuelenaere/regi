import Foundation
import CoreVideo

/// Converts decoded BGRA frames into IOSurface-backed `CVPixelBuffer`s and
/// hands them to the view via `onFrame`, off the main actor. This is the whole
/// "video output" for locally-decoded backends (VNC) — no WebRTC. The view
/// assigns the buffer's IOSurface to a `CALayer`, which CoreAnimation
/// composites at vsync. A `CVPixelBufferPool` avoids a fresh IOSurface
/// allocation per frame; the pool is rebuilt only when the frame size changes.
///
/// `@unchecked Sendable` because `onFrame` is set on the main actor but invoked
/// from the decode path — the `NSLock` guards that hand-off. Pixel format is
/// fixed at `kCVPixelFormatType_32BGRA`, matching the pixel format VNC forces
/// via `SetPixelFormat`, so `present` is a straight stride-aware `memcpy` with
/// no conversion.
public final class VideoFramePresenter: LocalVideoOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var _onFrame: (@Sendable (LocalVideoFrame) -> Void)?
    public var onFrame: (@Sendable (LocalVideoFrame) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFrame }
        set { lock.lock(); _onFrame = newValue; lock.unlock() }
    }

    private var pool: CVPixelBufferPool?
    private var poolWidth = 0, poolHeight = 0

    public init() {}

    /// Stop delivering frames (on disconnect).
    public func detach() { onFrame = nil }

    /// Convert one decoded BGRA frame and hand it to the view. Callable from
    /// any thread; must NOT be the main actor for a busy stream. `source` must
    /// hold at least `sourceBytesPerRow * height` bytes, laid out as tightly
    /// packed 32-bit BGRA rows.
    public func present(
        source: UnsafeRawBufferPointer,
        width: Int,
        height: Int,
        sourceBytesPerRow: Int
    ) {
        guard let cb = onFrame, width > 0, height > 0,
              let srcBase = source.baseAddress,
              let pb = pixelBuffer(width: width, height: height) else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let dstStride = CVPixelBufferGetBytesPerRow(pb)
            let copyBytes = min(dstStride, sourceBytesPerRow)
            for row in 0..<height {
                memcpy(base.advanced(by: row * dstStride),
                       srcBase.advanced(by: row * sourceBytesPerRow),
                       copyBytes)
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        cb(LocalVideoFrame(pixelBuffer: pb, width: width, height: height))
    }

    /// A pooled BGRA pixel buffer for `width`×`height`, rebuilding the pool
    /// when the frame size changes.
    private func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        if pool == nil || width != poolWidth || height != poolHeight {
            let pbAttrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            var newPool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pbAttrs as CFDictionary, &newPool) == kCVReturnSuccess else {
                return nil
            }
            pool = newPool; poolWidth = width; poolHeight = height
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess else { return nil }
        return pb
    }
}
