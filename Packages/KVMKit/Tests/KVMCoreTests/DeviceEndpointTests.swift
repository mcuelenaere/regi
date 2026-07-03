import XCTest
@testable import KVMCore

final class DeviceEndpointTests: XCTestCase {
    func testHTTPDefaultPortOmitted() {
        let endpoint = DeviceEndpoint(host: "192.168.1.42")
        XCTAssertEqual(
            endpoint.httpURL(path: "/device/status").absoluteString,
            "http://192.168.1.42/device/status"
        )
    }

    func testHTTPSDefaultPortOmitted() {
        let endpoint = DeviceEndpoint(host: "kvm.local", port: 443, useTLS: true)
        XCTAssertEqual(
            endpoint.httpURL(path: "/device").absoluteString,
            "https://kvm.local/device"
        )
    }

    func testHTTPCustomPortIncluded() {
        let endpoint = DeviceEndpoint(host: "kvm.local", port: 8080)
        XCTAssertEqual(
            endpoint.httpURL(path: "/device").absoluteString,
            "http://kvm.local:8080/device"
        )
    }

    func testWebSocketSchemeFollowsTLS() {
        let plain = DeviceEndpoint(host: "kvm.local")
        XCTAssertEqual(
            plain.webSocketURL(path: "/webrtc/signaling/client").absoluteString,
            "ws://kvm.local/webrtc/signaling/client"
        )

        let secure = DeviceEndpoint(host: "kvm.local", port: 443, useTLS: true)
        XCTAssertEqual(
            secure.webSocketURL(path: "/webrtc/signaling/client").absoluteString,
            "wss://kvm.local/webrtc/signaling/client"
        )
    }

    func testQueryItemsAppended() {
        let endpoint = DeviceEndpoint(host: "kvm.local")
        let url = endpoint.httpURL(path: "/x", queryItems: [
            URLQueryItem(name: "a", value: "1"),
            URLQueryItem(name: "b", value: "two words"),
        ])
        XCTAssertEqual(url.absoluteString, "http://kvm.local/x?a=1&b=two%20words")
    }

    func testIPv4Host() {
        let endpoint = DeviceEndpoint(host: "10.0.0.5", port: 80)
        XCTAssertEqual(
            endpoint.httpURL(path: "/device/status").absoluteString,
            "http://10.0.0.5/device/status"
        )
    }
}
