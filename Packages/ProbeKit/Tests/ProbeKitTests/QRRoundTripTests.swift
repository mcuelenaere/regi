import CoreImage
import Vision
import XCTest
@testable import ProbeKit

/// The full local half of the telemetry loop, with no hardware and no
/// permissions: `TelemetryFrame` → protobuf+LZFSE → `CIQRCodeGenerator` →
/// `VNDetectBarcodesRequest` → `payloadData` → bit-stream unwrap → decode.
///
/// This is the seam that hid the step 0 bug, where Vision reported a 100%
/// decode rate and handed back the raw QR bit stream rather than the payload.
/// Everything here except the camera/video path is the real code.
final class QRRoundTripTests: XCTestCase {

    private func encodeToQR(_ payload: Data, level: String = "H") throws -> CGImage {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(payload, forKey: "inputMessage")
        filter.setValue(level, forKey: "inputCorrectionLevel")
        let out = try XCTUnwrap(filter.outputImage)
        // Scale up without interpolation, as the probe does: soft module edges
        // are a real cause of marginal decodes.
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return try XCTUnwrap(CIContext().createCGImage(scaled, from: scaled.extent))
    }

    private func decodeQR(_ image: CGImage) throws -> Data {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let obs = try XCTUnwrap(request.results?.first, "Vision found no QR code")

        guard #available(macOS 15.0, *), let raw = obs.payloadData else {
            throw XCTSkip("payloadData needs macOS 15+; the probe reports which path it used")
        }
        return try XCTUnwrap(QRBitstream.bytePayload(from: raw),
                             "bit-stream unwrap failed — payloadData is not the payload")
    }

    func testFrameSurvivesARealQREncodeAndVisionDecode() throws {
        let frame = Fixtures.frame(Fixtures.typing(events: 160))
        let (encoded, capped) = try FrameCodec.encodeCapped(frame)

        let image = try encodeToQR(encoded)
        let recovered = try decodeQR(image)

        XCTAssertEqual(recovered, encoded, "QR round trip must be byte-exact")
        XCTAssertEqual(try FrameCodec.decode(recovered).events, capped.events)
    }

    /// Mixed traffic is the densest shape, so it is the one that would first
    /// overflow the symbol.
    func testDensestTrafficStillFitsAndDecodes() throws {
        let (encoded, capped) = try FrameCodec.encodeCapped(
            Fixtures.frame(Fixtures.mixed(count: 400)))
        XCTAssertLessThanOrEqual(encoded.count, FrameCodec.defaultMaxBytes)

        let recovered = try decodeQR(try encodeToQR(encoded))
        XCTAssertEqual(try FrameCodec.decode(recovered).events, capped.events)
    }

    /// The budget exists because exceeding it silently bumps the QR version:
    /// more modules, smaller modules at the same band size, and the loop breaks
    /// with no error. Pin the symbol size the rig was verified against.
    func testBudgetKeepsTheSymbolAtTheVerifiedSize() throws {
        let (encoded, _) = try FrameCodec.encodeCapped(Fixtures.frame(Fixtures.mixed(count: 400)))
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(encoded, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        let modules = Int(try XCTUnwrap(filter.outputImage).extent.width.rounded())

        // 179 = version 40 plus a 1-module quiet zone each side, which step 0
        // verified end to end at 240/240 reads through the real rig.
        XCTAssertLessThanOrEqual(modules, 179,
            "symbol grew to \(modules) modules; at a fixed band size that shrinks "
            + "each module and breaks decoding with no error anywhere")
    }

    func testEmptyAndTinyFramesAlsoRoundTrip() throws {
        for events in [[], Fixtures.typing(events: 2)] {
            let (encoded, _) = try FrameCodec.encodeCapped(Fixtures.frame(events))
            let recovered = try decodeQR(try encodeToQR(encoded))
            XCTAssertEqual(recovered, encoded)
        }
    }
}
