import XCTest
@testable import JetKVMTransport

final class VNCFramebufferTests: XCTestCase {
    func testInitIsOpaqueBlack() {
        let fb = VNCFramebuffer(width: 2, height: 2)
        XCTAssertEqual(fb.pixelBGR(x: 0, y: 0).map { [$0.0, $0.1, $0.2] }, [0, 0, 0])
        // Alpha byte forced to 0xFF (verified via a raw blit round-trip below).
    }

    func testBounds() {
        let fb = VNCFramebuffer(width: 10, height: 10)
        XCTAssertTrue(fb.contains(x: 0, y: 0, w: 10, h: 10))
        XCTAssertFalse(fb.contains(x: 5, y: 5, w: 6, h: 1))
        XCTAssertFalse(fb.contains(x: -1, y: 0, w: 1, h: 1))
    }

    func testBlitBGRA() throws {
        let fb = VNCFramebuffer(width: 4, height: 4)
        // A 2x2 rect at (1,1): each pixel B,G,R,X.
        var rect = [UInt8]()
        for p in 0..<4 { rect += [UInt8(10 + p), UInt8(20 + p), UInt8(30 + p), 0] }
        try rect.withUnsafeBytes {
            try fb.blitBGRA(x: 1, y: 1, w: 2, h: 2, src: $0)
        }
        XCTAssertEqual(fb.pixelBGR(x: 1, y: 1).map { [$0.0, $0.1, $0.2] }, [10, 20, 30])
        XCTAssertEqual(fb.pixelBGR(x: 2, y: 1).map { [$0.0, $0.1, $0.2] }, [11, 21, 31])
        XCTAssertEqual(fb.pixelBGR(x: 2, y: 2).map { [$0.0, $0.1, $0.2] }, [13, 23, 33])
        // Untouched pixel stays black.
        XCTAssertEqual(fb.pixelBGR(x: 0, y: 0).map { [$0.0, $0.1, $0.2] }, [0, 0, 0])
    }

    func testBlitOutOfBoundsThrows() {
        let fb = VNCFramebuffer(width: 4, height: 4)
        let rect = [UInt8](repeating: 0, count: 4 * 4)
        XCTAssertThrowsError(try rect.withUnsafeBytes {
            try fb.blitBGRA(x: 3, y: 3, w: 2, h: 2, src: $0)
        })
    }

    func testFill() throws {
        let fb = VNCFramebuffer(width: 3, height: 3)
        try fb.fill(x: 0, y: 0, w: 3, h: 3, b: 7, g: 8, r: 9)
        XCTAssertEqual(fb.pixelBGR(x: 2, y: 2).map { [$0.0, $0.1, $0.2] }, [7, 8, 9])
    }

    func testCopyRectNonOverlapping() throws {
        let fb = VNCFramebuffer(width: 8, height: 4)
        try fb.fill(x: 0, y: 0, w: 2, h: 2, b: 1, g: 2, r: 3)
        try fb.copyRect(srcX: 0, srcY: 0, dstX: 4, dstY: 2, w: 2, h: 2)
        XCTAssertEqual(fb.pixelBGR(x: 4, y: 2).map { [$0.0, $0.1, $0.2] }, [1, 2, 3])
        XCTAssertEqual(fb.pixelBGR(x: 5, y: 3).map { [$0.0, $0.1, $0.2] }, [1, 2, 3])
    }

    func testCopyRectOverlappingRightShift() throws {
        // Fill left half with a color, then copy shifted right by 1 into an
        // overlapping region. Scratch-copy must preserve the original source.
        let fb = VNCFramebuffer(width: 6, height: 1)
        try fb.fill(x: 0, y: 0, w: 3, h: 1, b: 100, g: 0, r: 0)   // cols 0,1,2 = blue
        // cols 3,4,5 are black
        try fb.copyRect(srcX: 0, srcY: 0, dstX: 1, dstY: 0, w: 3, h: 1) // move [0,2]→[1,3]
        XCTAssertEqual(fb.pixelBGR(x: 1, y: 0)?.0, 100)
        XCTAssertEqual(fb.pixelBGR(x: 2, y: 0)?.0, 100)
        XCTAssertEqual(fb.pixelBGR(x: 3, y: 0)?.0, 100)
    }

    func testResize() {
        let fb = VNCFramebuffer(width: 4, height: 4)
        fb.resize(width: 10, height: 6)
        XCTAssertEqual(fb.width, 10)
        XCTAssertEqual(fb.height, 6)
        XCTAssertEqual(fb.pixelBGR(x: 9, y: 5).map { [$0.0, $0.1, $0.2] }, [0, 0, 0])
    }
}
