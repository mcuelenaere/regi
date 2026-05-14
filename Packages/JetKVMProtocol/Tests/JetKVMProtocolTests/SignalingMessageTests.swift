import XCTest
@testable import JetKVMProtocol

/// Round-trip and asymmetry tests for the WebRTC signaling envelope.
/// The defining peculiarity: the offer wraps `sd` in an object, but the
/// answer is a bare base64 string directly under `data`.
final class SignalingMessageTests: XCTestCase {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Deterministic key order so we can compare to literal strings.
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    // MARK: - device-metadata

    func testDecodeDeviceMetadata() throws {
        let json = #"""
        {"type":"device-metadata","data":{"deviceVersion":"v0.4.7"}}
        """#.data(using: .utf8)!
        let msg = try decoder.decode(SignalingMessage.self, from: json)
        XCTAssertEqual(msg, .deviceMetadata(DeviceMetadata(deviceVersion: "v0.4.7")))
    }

    func testDecodeDeviceMetadataWithEmptyVersion() throws {
        // An empty deviceVersion indicates legacy firmware; we surface it
        // here so callers can decide to treat it as fatal (see plan).
        let json = #"""
        {"type":"device-metadata","data":{"deviceVersion":""}}
        """#.data(using: .utf8)!
        let msg = try decoder.decode(SignalingMessage.self, from: json)
        XCTAssertEqual(msg, .deviceMetadata(DeviceMetadata(deviceVersion: "")))
    }

    // MARK: - firmwareIsAtLeast

    func testFirmwareIsAtLeastEqualPasses() {
        let m = DeviceMetadata(deviceVersion: "0.5.9")
        XCTAssertTrue(m.firmwareIsAtLeast("0.5.9"))
    }

    func testFirmwareIsAtLeastHigherPatchPasses() {
        let m = DeviceMetadata(deviceVersion: "0.5.10")
        XCTAssertTrue(m.firmwareIsAtLeast("0.5.9"))
    }

    func testFirmwareIsAtLeastLowerPatchFails() {
        let m = DeviceMetadata(deviceVersion: "0.5.8")
        XCTAssertFalse(m.firmwareIsAtLeast("0.5.9"))
    }

    func testFirmwareIsAtLeastHigherMinorPasses() {
        let m = DeviceMetadata(deviceVersion: "0.6.0")
        XCTAssertTrue(m.firmwareIsAtLeast("0.5.9"))
    }

    func testFirmwareIsAtLeastHigherMajorPasses() {
        let m = DeviceMetadata(deviceVersion: "1.0.0")
        XCTAssertTrue(m.firmwareIsAtLeast("0.5.9"))
    }

    func testFirmwareIsAtLeastStripsLeadingV() {
        let m = DeviceMetadata(deviceVersion: "v0.5.9")
        XCTAssertTrue(m.firmwareIsAtLeast("0.5.9"))
        XCTAssertTrue(m.firmwareIsAtLeast("v0.5.9"))
    }

    func testFirmwareIsAtLeastShortVersionPadsWithZeros() {
        // "0.5" treated as "0.5.0" → less than "0.5.9".
        XCTAssertFalse(DeviceMetadata(deviceVersion: "0.5").firmwareIsAtLeast("0.5.9"))
        // "0.5.9" trivially >= "0.5" (i.e. "0.5.0").
        XCTAssertTrue(DeviceMetadata(deviceVersion: "0.5.9").firmwareIsAtLeast("0.5"))
    }

    func testFirmwareIsAtLeastFailsClosedOnEmpty() {
        // Legacy firmware sends an empty deviceVersion; we already
        // treat that as a hard error elsewhere, but the gate must
        // stay off so it can't accidentally trip a feature path.
        XCTAssertFalse(DeviceMetadata(deviceVersion: "").firmwareIsAtLeast("0.5.9"))
    }

    func testFirmwareIsAtLeastFailsClosedOnNonNumeric() {
        XCTAssertFalse(DeviceMetadata(deviceVersion: "garbage").firmwareIsAtLeast("0.5.9"))
        XCTAssertFalse(DeviceMetadata(deviceVersion: "0.5.x").firmwareIsAtLeast("0.5.9"))
    }

    // MARK: - offer

    func testEncodeOfferWrapsSdpInSdField() throws {
        let msg = SignalingMessage.offer(sdpBase64: "BASE64SDP")
        let data = try encoder.encode(msg)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(json, #"{"data":{"sd":"BASE64SDP"},"type":"offer"}"#)
    }

    func testEncodeDecodeOfferRoundTrip() throws {
        let msg = SignalingMessage.offer(sdpBase64: "abcd1234==")
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(SignalingMessage.self, from: data)
        XCTAssertEqual(decoded, msg)
    }

    // MARK: - answer (asymmetric — bare string in `data`)

    func testDecodeAnswerExpectsBareStringInData() throws {
        let json = #"""
        {"type":"answer","data":"BASE64SDPANSWER"}
        """#.data(using: .utf8)!
        let msg = try decoder.decode(SignalingMessage.self, from: json)
        XCTAssertEqual(msg, .answer(sdpBase64: "BASE64SDPANSWER"))
    }

    func testEncodeAnswerProducesBareStringInData() throws {
        let msg = SignalingMessage.answer(sdpBase64: "ANS")
        let data = try encoder.encode(msg)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(json, #"{"data":"ANS","type":"answer"}"#)
    }

    func testDecodeAnswerWithSdWrapperFails() throws {
        // Make the asymmetry explicit: if the server ever changed to wrap
        // the answer like the offer, this would deserialize differently
        // and we'd want the test to break loudly.
        let json = #"""
        {"type":"answer","data":{"sd":"BASE64"}}
        """#.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(SignalingMessage.self, from: json))
    }

    // MARK: - new-ice-candidate

    func testDecodeIceCandidateAllFields() throws {
        let json = #"""
        {"type":"new-ice-candidate","data":{"candidate":"candidate:foo","sdpMid":"0","sdpMLineIndex":0,"usernameFragment":"abcd"}}
        """#.data(using: .utf8)!
        let msg = try decoder.decode(SignalingMessage.self, from: json)
        guard case .newIceCandidate(let c) = msg else {
            return XCTFail("expected newIceCandidate, got \(msg)")
        }
        XCTAssertEqual(c.candidate, "candidate:foo")
        XCTAssertEqual(c.sdpMid, "0")
        XCTAssertEqual(c.sdpMLineIndex, 0)
        XCTAssertEqual(c.usernameFragment, "abcd")
    }

    func testDecodeIceCandidateMinimal() throws {
        // pion serializes optional fields with omitempty; a minimal candidate
        // may carry only the candidate string.
        let json = #"""
        {"type":"new-ice-candidate","data":{"candidate":"end-of-candidates"}}
        """#.data(using: .utf8)!
        let msg = try decoder.decode(SignalingMessage.self, from: json)
        guard case .newIceCandidate(let c) = msg else {
            return XCTFail("expected newIceCandidate, got \(msg)")
        }
        XCTAssertEqual(c.candidate, "end-of-candidates")
        XCTAssertNil(c.sdpMid)
        XCTAssertNil(c.sdpMLineIndex)
    }

    // MARK: - unknown type

    func testDecodeUnknownTypeThrows() throws {
        let json = #"""
        {"type":"some-future-thing","data":{}}
        """#.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(SignalingMessage.self, from: json))
    }
}
