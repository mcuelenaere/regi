import XCTest
@testable import RegiE2ECore

final class VideoGeometryTests: XCTestCase {

    func testParsesRegisMultiplicationSign() {
        XCTAssertEqual(VideoGeometry.parseResolution("1920×1080"), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(VideoGeometry.parseResolution("1280x720"), CGSize(width: 1280, height: 720))
        XCTAssertNil(VideoGeometry.parseResolution("no signal"))
        XCTAssertNil(VideoGeometry.parseResolution("1920"))
        XCTAssertNil(VideoGeometry.parseResolution("0×0"))
    }

    /// A 16:9 source in a wider view pillarboxes; in a taller view it letterboxes.
    func testLetterboxAndPillarbox() {
        let letterboxed = VideoGeometry(viewFrame: CGRect(x: 0, y: 100, width: 1512, height: 900),
                                        sourceSize: CGSize(width: 1920, height: 1080))
        let r = letterboxed.contentRect
        XCTAssertEqual(r.width, 1512, accuracy: 0.01, "full width when the video is wider")
        XCTAssertEqual(r.height, 1512 * 9 / 16, accuracy: 0.01)
        XCTAssertEqual(r.midY, letterboxed.viewFrame.midY, accuracy: 0.01, "centred vertically")

        let pillarboxed = VideoGeometry(viewFrame: CGRect(x: 0, y: 0, width: 1600, height: 400),
                                        sourceSize: CGSize(width: 1024, height: 768))
        let p = pillarboxed.contentRect
        XCTAssertEqual(p.height, 400, accuracy: 0.01, "full height when the view is wider")
        XCTAssertEqual(p.width, 400 * 1024 / 768, accuracy: 0.01)
        XCTAssertEqual(p.midX, pillarboxed.viewFrame.midX, accuracy: 0.01, "centred horizontally")
    }

    func testRoundTripsThroughScreenPoints() {
        let g = VideoGeometry(viewFrame: CGRect(x: 0, y: 94, width: 1512, height: 850),
                              sourceSize: CGSize(width: 1920, height: 1080))
        for px in [CGPoint(x: 0, y: 0), CGPoint(x: 960, y: 540), CGPoint(x: 1919, y: 1079)] {
            let back = g.framebufferPixel(forScreenPoint: g.screenPoint(forFramebufferPixel: px))
            XCTAssertEqual(back.x, px.x, accuracy: 0.01)
            XCTAssertEqual(back.y, px.y, accuracy: 0.01)
        }
    }

    /// The centre pixel must land at the centre of the content rect: a
    /// half-pixel bias is enough to round onto the neighbouring pixel.
    func testCentrePixelLandsAtTheCentre() {
        let g = VideoGeometry(viewFrame: CGRect(x: 0, y: 94, width: 1512, height: 850),
                              sourceSize: CGSize(width: 1920, height: 1080))
        let p = g.screenPoint(forFramebufferPixel: CGPoint(x: 959.5, y: 539.5))
        XCTAssertEqual(p.x, g.contentRect.midX, accuracy: 0.01)
        XCTAssertEqual(p.y, g.contentRect.midY, accuracy: 0.01)
    }

    /// This number decides what pointer tolerance a scenario can demand.
    func testPixelsPerPointIsTheAccuracyFloor() {
        let shrunk = VideoGeometry(viewFrame: CGRect(x: 0, y: 0, width: 960, height: 540),
                                   sourceSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(shrunk.pixelsPerPoint, 2.0, accuracy: 0.001,
                       "a half-size view can only address every 2nd framebuffer pixel")

        let full = VideoGeometry(viewFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                 sourceSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(full.pixelsPerPoint, 1.0, accuracy: 0.001)
    }

    func testDegenerateInputsDoNotCrash() {
        let g = VideoGeometry(viewFrame: .zero, sourceSize: .zero)
        XCTAssertEqual(g.contentRect, .zero)
        XCTAssertEqual(g.pixelsPerPoint, 0)
        XCTAssertEqual(g.framebufferPixel(forScreenPoint: CGPoint(x: 10, y: 10)), .zero)
    }
}
