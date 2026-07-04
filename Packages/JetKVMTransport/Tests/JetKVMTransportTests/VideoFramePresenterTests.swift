import XCTest
import CoreVideo
@testable import JetKVMTransport

final class VideoFramePresenterTests: XCTestCase {
    /// A frame presented at W×H yields a BGRA IOSurface-backed pixel buffer of
    /// that size, and the source bytes land in the buffer.
    func testPresentEmitsBGRAIOSurfaceFrame() {
        let presenter = VideoFramePresenter()
        var received: LocalVideoFrame?
        presenter.onFrame = { received = $0 }

        let (w, h) = (4, 3)
        var src = [UInt8](repeating: 0, count: w * h * 4)
        // Distinct byte per pixel-channel so we can verify the copy.
        for i in src.indices { src[i] = UInt8(i & 0xFF) }
        src.withUnsafeBytes { presenter.present(source: $0, width: w, height: h, sourceBytesPerRow: w * 4) }

        let frame = try? XCTUnwrap(received)
        XCTAssertEqual(frame?.width, w)
        XCTAssertEqual(frame?.height, h)
        guard let pb = frame?.pixelBuffer else { return XCTFail("no pixel buffer") }
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(pb), kCVPixelFormatType_32BGRA)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(pb), "must be IOSurface-backed for CALayer scan-out")

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<h {
            for col in 0..<(w * 4) {
                XCTAssertEqual(base[row * stride + col], src[row * w * 4 + col],
                               "pixel byte mismatch at row \(row) col \(col)")
            }
        }
    }

    /// Presenting a new size rebuilds the pool: the emitted buffer matches the
    /// new dimensions (a stale pool would hand back the old size or fail).
    func testPoolRebuildsOnSizeChange() {
        let presenter = VideoFramePresenter()
        var last: LocalVideoFrame?
        presenter.onFrame = { last = $0 }

        let small = [UInt8](repeating: 0x11, count: 2 * 2 * 4)
        small.withUnsafeBytes { presenter.present(source: $0, width: 2, height: 2, sourceBytesPerRow: 2 * 4) }
        XCTAssertEqual(last?.width, 2)
        XCTAssertEqual(last.map { CVPixelBufferGetWidth($0.pixelBuffer) }, 2)

        let big = [UInt8](repeating: 0x22, count: 8 * 5 * 4)
        big.withUnsafeBytes { presenter.present(source: $0, width: 8, height: 5, sourceBytesPerRow: 8 * 4) }
        XCTAssertEqual(last?.width, 8)
        XCTAssertEqual(last?.height, 5)
        XCTAssertEqual(last.map { CVPixelBufferGetWidth($0.pixelBuffer) }, 8)
        XCTAssertEqual(last.map { CVPixelBufferGetHeight($0.pixelBuffer) }, 5)
    }

    /// No `onFrame` set → present is a no-op (doesn't crash).
    func testPresentWithoutHandlerIsNoOp() {
        let presenter = VideoFramePresenter()
        let src = [UInt8](repeating: 0, count: 4 * 4 * 4)
        src.withUnsafeBytes { presenter.present(source: $0, width: 4, height: 4, sourceBytesPerRow: 4 * 4) }
    }
}
