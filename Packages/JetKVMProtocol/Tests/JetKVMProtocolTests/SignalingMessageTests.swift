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

    func testDecodeDeviceMetadataWithSupportedOpcodes() throws {
        // Go's `encoding/json` serializes []byte as base64. SupportedInputOpcodes()
        // returns {0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09} which is
        // base64 "AgMEBQYHCAk=".
        let json = #"""
        {"type":"device-metadata","data":{"deviceVersion":"v0.5.0","supportedHIDRPCOpcodes":"AgMEBQYHCAk="}}
        """#.data(using: .utf8)!
        let msg = try decoder.decode(SignalingMessage.self, from: json)
        guard case .deviceMetadata(let metadata) = msg else {
            return XCTFail("expected deviceMetadata, got \(msg)")
        }
        XCTAssertEqual(metadata.deviceVersion, "v0.5.0")
        XCTAssertEqual(
            metadata.supportedHIDRPCOpcodes,
            Set<UInt8>([0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09])
        )
    }

    func testDecodeDeviceMetadataAbsentOpcodesIsNil() throws {
        // Legacy firmware leaves the field off entirely.
        let json = #"""
        {"type":"device-metadata","data":{"deviceVersion":"v0.4.7"}}
        """#.data(using: .utf8)!
        let msg = try decoder.decode(SignalingMessage.self, from: json)
        guard case .deviceMetadata(let metadata) = msg else {
            return XCTFail("expected deviceMetadata, got \(msg)")
        }
        XCTAssertNil(metadata.supportedHIDRPCOpcodes)
    }

    func testDecodeDeviceMetadataMalformedBase64IsNil() throws {
        // Garbled base64 shouldn't fail the whole metadata decode —
        // we'd rather fall back to the JSON-RPC path than crash the
        // connect flow.
        let json = #"""
        {"type":"device-metadata","data":{"deviceVersion":"v0.5.0","supportedHIDRPCOpcodes":"not-base64!!!"}}
        """#.data(using: .utf8)!
        let msg = try decoder.decode(SignalingMessage.self, from: json)
        guard case .deviceMetadata(let metadata) = msg else {
            return XCTFail("expected deviceMetadata, got \(msg)")
        }
        XCTAssertNil(metadata.supportedHIDRPCOpcodes)
    }

    func testEncodeDeviceMetadataWithOpcodesRoundTrip() throws {
        // Round-trip: encode our model, decode it back, expect equality.
        // Sorted-keys output makes the test deterministic. Sorting the
        // opcode set inside encode() means the base64 output is also
        // deterministic.
        let original = DeviceMetadata(
            deviceVersion: "v0.5.0",
            supportedHIDRPCOpcodes: [0x02, 0x04, 0x06]
        )
        let envelope = SignalingMessage.deviceMetadata(original)
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(SignalingMessage.self, from: data)
        XCTAssertEqual(decoded, envelope)
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
