import XCTest
@testable import PiKVMKit

final class PiKVMEventTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testKeyEvent() throws {
        let o = try json(PiKVMEvent.key(code: "KeyA", pressed: true))
        XCTAssertEqual(o["event_type"] as? String, "key")
        let ev = try XCTUnwrap(o["event"] as? [String: Any])
        XCTAssertEqual(ev["key"] as? String, "KeyA")
        XCTAssertEqual(ev["state"] as? Bool, true)
    }

    func testMouseMove() throws {
        let o = try json(PiKVMEvent.mouseMove(x: -32768, y: 32767))
        XCTAssertEqual(o["event_type"] as? String, "mouse_move")
        let to = try XCTUnwrap((o["event"] as? [String: Any])?["to"] as? [String: Any])
        XCTAssertEqual(to["x"] as? Int, -32768)
        XCTAssertEqual(to["y"] as? Int, 32767)
    }

    func testMouseRelativeSquash() throws {
        let o = try json(PiKVMEvent.mouseRelative(dx: 5, dy: -7))
        XCTAssertEqual(o["event_type"] as? String, "mouse_relative")
        let ev = try XCTUnwrap(o["event"] as? [String: Any])
        XCTAssertEqual(ev["squash"] as? Bool, true)
        let delta = try XCTUnwrap(ev["delta"] as? [String: Any])
        XCTAssertEqual(delta["x"] as? Int, 5)
        XCTAssertEqual(delta["y"] as? Int, -7)
    }

    func testMouseButton() throws {
        let o = try json(PiKVMEvent.mouseButton(.right, pressed: false))
        XCTAssertEqual(o["event_type"] as? String, "mouse_button")
        let ev = try XCTUnwrap(o["event"] as? [String: Any])
        XCTAssertEqual(ev["button"] as? String, "right")
        XCTAssertEqual(ev["state"] as? Bool, false)
    }

    func testMouseWheel() throws {
        let o = try json(PiKVMEvent.mouseWheel(dx: 0, dy: 5))
        XCTAssertEqual(o["event_type"] as? String, "mouse_wheel")
        let delta = try XCTUnwrap((o["event"] as? [String: Any])?["delta"] as? [String: Any])
        XCTAssertEqual(delta["x"] as? Int, 0)
        XCTAssertEqual(delta["y"] as? Int, 5)
    }

    // MARK: - Mapping helpers

    func testAbsoluteCoordinateEndpoints() {
        XCTAssertEqual(PiKVMEvent.absoluteCoordinate(fromNormalized: 0), -32768)
        XCTAssertEqual(PiKVMEvent.absoluteCoordinate(fromNormalized: 32767), 32767)
    }

    func testAbsoluteCoordinateClamps() {
        XCTAssertEqual(PiKVMEvent.absoluteCoordinate(fromNormalized: -5), -32768)
        XCTAssertEqual(PiKVMEvent.absoluteCoordinate(fromNormalized: 40000), 32767)
    }

    func testAbsoluteCoordinateMidpointIsCentered() {
        // 16384/32767 ≈ 0.5 → maps near 0 (origin is screen center).
        let mid = PiKVMEvent.absoluteCoordinate(fromNormalized: 16384)
        XCTAssertLessThanOrEqual(abs(mid), 2)
    }

    func testWheelDelta() {
        // Inverted to match PiKVM's axis direction (sign · -rate).
        XCTAssertEqual(PiKVMEvent.wheelDelta(fromTick: 0), 0)
        XCTAssertEqual(PiKVMEvent.wheelDelta(fromTick: 3), -5)
        XCTAssertEqual(PiKVMEvent.wheelDelta(fromTick: -2), 5)
        XCTAssertEqual(PiKVMEvent.wheelDelta(fromTick: 9, rate: 2), -2)
    }

    // MARK: - Inbound

    func testIncomingType() {
        let data = Data(#"{"event_type":"hid","event":{}}"#.utf8)
        XCTAssertEqual(PiKVMEvent.incomingType(data), "hid")
    }

    func testDecodeHIDStateAbsolute() throws {
        let data = Data(#"{"event_type":"hid","event":{"online":true,"mouse":{"online":true,"absolute":false}}}"#.utf8)
        let hid = try XCTUnwrap(PiKVMEvent.decodeHIDState(data))
        XCTAssertEqual(hid.online, true)
        XCTAssertEqual(hid.mouse?.absolute, false)
        XCTAssertEqual(hid.mouse?.online, true)
    }
}
