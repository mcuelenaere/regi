import XCTest
@testable import JetKVMKit

final class AuthTests: XCTestCase {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func testDeviceStatusDecodesIsSetupTrue() throws {
        let json = #"{"isSetup":true}"#.data(using: .utf8)!
        let decoded = try decoder.decode(DeviceStatus.self, from: json)
        XCTAssertEqual(decoded, DeviceStatus(isSetup: true))
    }

    func testDeviceStatusDecodesIsSetupFalse() throws {
        let json = #"{"isSetup":false}"#.data(using: .utf8)!
        let decoded = try decoder.decode(DeviceStatus.self, from: json)
        XCTAssertEqual(decoded, DeviceStatus(isSetup: false))
    }

    func testLocalDeviceDecodesPasswordMode() throws {
        let json = #"""
        {"authMode":"password","deviceId":"abc-123","loopbackOnly":false}
        """#.data(using: .utf8)!
        let decoded = try decoder.decode(LocalDevice.self, from: json)
        XCTAssertEqual(decoded.authMode, .password)
        XCTAssertEqual(decoded.deviceID, "abc-123")
        XCTAssertFalse(decoded.loopbackOnly)
    }

    func testLocalDeviceDecodesNoPasswordMode() throws {
        let json = #"""
        {"authMode":"noPassword","deviceId":"xyz","loopbackOnly":true}
        """#.data(using: .utf8)!
        let decoded = try decoder.decode(LocalDevice.self, from: json)
        XCTAssertEqual(decoded.authMode, .noPassword)
        XCTAssertTrue(decoded.loopbackOnly)
    }

    func testLocalDeviceDecodesNullAuthMode() throws {
        let json = #"""
        {"authMode":null,"deviceId":"x","loopbackOnly":false}
        """#.data(using: .utf8)!
        let decoded = try decoder.decode(LocalDevice.self, from: json)
        XCTAssertNil(decoded.authMode)
    }

    func testAuthModeUnknownValueRoundTrips() throws {
        // The server represents "unset" as an empty string before setup
        // (`web.go:824` derives isSetup from `LocalAuthMode != ""`). We don't
        // typically see authMode set to "" because /device requires auth, but
        // we still want decode to be tolerant.
        let json = #""""#.data(using: .utf8)!
        let decoded = try decoder.decode(AuthMode.self, from: json)
        XCTAssertEqual(decoded, .unknown(""))
        let encoded = try encoder.encode(decoded)
        XCTAssertEqual(encoded, json)
    }

    func testLoginRequestEncodesPasswordField() throws {
        let req = LoginRequest(password: "hunter2")
        let data = try encoder.encode(req)
        let decoded = try decoder.decode([String: String].self, from: data)
        XCTAssertEqual(decoded, ["password": "hunter2"])
    }
}
