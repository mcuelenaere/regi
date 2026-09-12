import CoreGraphics
import XCTest
@testable import KVMCore

final class AbsolutePointerTests: XCTestCase {
    func testNormalizeSpansTheFullWireRange() {
        XCTAssertEqual(AbsolutePointer.normalize(0, extent: 1920), 0)
        XCTAssertEqual(AbsolutePointer.normalize(1920, extent: 1920), 32767)
        XCTAssertEqual(AbsolutePointer.normalize(960, extent: 1920), 16383)
    }

    func testNormalizeClampsOutOfRange() {
        XCTAssertEqual(AbsolutePointer.normalize(-50, extent: 1920), 0)
        XCTAssertEqual(AbsolutePointer.normalize(5000, extent: 1920), 32767)
    }

    func testDegenerateExtentsDoNotDivideByZero() {
        XCTAssertEqual(AbsolutePointer.normalize(10, extent: 0), 0)
        XCTAssertEqual(AbsolutePointer.unitsPerPixel(sourceExtent: 0), 1)
    }

    /// The reciprocal has to agree with the mapping, or a "did this move far
    /// enough to matter" check and the conversion drift apart silently.
    func testUnitsPerPixelIsTheInverseOfNormalize() {
        for extent in [CGFloat(1280), 1920, 2560, 3840] {
            let perPixel = AbsolutePointer.unitsPerPixel(sourceExtent: extent)
            let onePixelIn = AbsolutePointer.normalize(1, extent: extent)
            XCTAssertEqual(CGFloat(onePixelIn), perPixel, accuracy: 1,
                           "one pixel should be one pixel's worth of units at \(extent)")
        }
    }

    /// The case this exists for: a hand's tremor moves the normalized value
    /// without moving the host's cursor, and must read as "no movement".
    func testTremorIsSmallerThanOnePixel() {
        let perPixel = AbsolutePointer.unitsPerPixel(sourceExtent: 1920)
        XCTAssertGreaterThan(perPixel, 6, "a six-unit tremor at 1920 wide is sub-pixel")
        XCTAssertLessThan(perPixel, 18)
    }

    /// A real one-pixel move must not be mistaken for a tremor at any of the
    /// resolutions a KVM realistically carries.
    func testOnePixelMoveAlwaysCountsAsMovement() {
        for extent in [CGFloat(640), 1280, 1920, 2560, 3840] {
            let perPixel = AbsolutePointer.unitsPerPixel(sourceExtent: extent)
            let a = AbsolutePointer.normalize(100, extent: extent)
            let b = AbsolutePointer.normalize(101, extent: extent)
            XCTAssertGreaterThanOrEqual(CGFloat(abs(b - a)), perPixel - 1,
                                        "one pixel at \(extent) must clear the threshold")
        }
    }
}

/// The backends' coordinate mappings were written out by hand with the wire
/// range inline. Routing them through `AbsolutePointer` must not move a single
/// pixel, so these pin the new arithmetic against the old, exactly.
final class AbsolutePointerEquivalenceTests: XCTestCase {
    /// VNC: normalized → zero-based pixel index. Was
    /// `Int((Double(n) / 32767.0) * Double(extent - 1))`.
    func testPixelIndexMatchesTheFormulaItReplaced() {
        for extent in [640, 1280, 1920, 2560, 3840, 1] {
            for n in stride(from: Int32(0), through: 32767, by: 97) {
                let old = Int((Double(n) / 32767.0) * Double(extent - 1))
                let new = AbsolutePointer.pixelIndex(fromNormalized: n, extent: extent)
                XCTAssertEqual(new, old, "extent \(extent), n \(n)")
            }
            XCTAssertEqual(AbsolutePointer.pixelIndex(fromNormalized: 32767, extent: extent),
                           extent - 1, "the top of the range is the last pixel")
            XCTAssertEqual(AbsolutePointer.pixelIndex(fromNormalized: 0, extent: extent), 0)
        }
    }

    func testPixelIndexSurvivesADegenerateExtent() {
        XCTAssertEqual(AbsolutePointer.pixelIndex(fromNormalized: 500, extent: 0), 0)
    }
}
