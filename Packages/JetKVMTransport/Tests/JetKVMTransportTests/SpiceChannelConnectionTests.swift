import XCTest
import Network
@testable import JetKVMTransport

/// Exercises SpiceChannelConnection end-to-end over a real loopback socket
/// against an in-process fake SPICE server (see FakeSpiceServer). Covers the
/// TCP connect, link handshake, cap negotiation, and RSA-OAEP ticket auth.
final class SpiceChannelConnectionTests: XCTestCase {

    func testHandshakeAndTicketAuthOverLoopback() async throws {
        let server = try FakeSpiceServer()
        let port = try await server.start()
        defer { server.stop() }

        let conn = SpiceChannelConnection(
            host: "127.0.0.1", port: port, useTLS: false, allowSelfSigned: false,
            channelType: .main, channelID: 0
        )

        // Run client handshake and server capture concurrently.
        async let serverPassword = server.capturedPassword()
        let reply = try await conn.connect(password: "secret123")
        let captured = try await serverPassword

        XCTAssertEqual(reply.error, SpiceProtocol.LinkErr.ok.rawValue)
        XCTAssertEqual(reply.pubKey, server.spki)
        XCTAssertEqual(captured, "secret123", "server must decrypt the client's ticket")

        // Mini header should have been negotiated (server advertised it).
        let mini = await conn.useMiniHeader
        XCTAssertTrue(mini)

        await conn.close()
    }

    func testHandshakeThroughConnectProxy() async throws {
        // Fake server also acts as a plaintext HTTP CONNECT proxy.
        let server = try FakeSpiceServer(expectConnect: true)
        let proxyPort = try await server.start()
        defer { server.stop() }

        // Target host/port are the opaque values the proxy would route on
        // (mirrors Proxmox's spiceproxy token + tls-port).
        let conn = SpiceChannelConnection(
            host: "pvespiceproxy:token:104", port: 61001,
            useTLS: false, allowSelfSigned: false,
            channelType: .main, channelID: 0,
            proxy: SpiceProxy(host: "127.0.0.1", port: proxyPort)
        )

        async let serverPassword = server.capturedPassword()
        let reply = try await conn.connect(password: "tunnelpw")
        let captured = try await serverPassword

        XCTAssertEqual(reply.error, SpiceProtocol.LinkErr.ok.rawValue)
        XCTAssertEqual(captured, "tunnelpw", "SPICE ticket flowed through the CONNECT tunnel")
        XCTAssertEqual(server.capturedTarget, "pvespiceproxy:token:104:61001",
                       "proxy received the CONNECT target")
        await conn.close()
    }

    func testProxyURLParsing() {
        XCTAssertEqual(SpiceProxy(url: "http://pve.example.com:3128"),
                       SpiceProxy(host: "pve.example.com", port: 3128))
        XCTAssertEqual(SpiceProxy(url: "pve.example.com"),
                       SpiceProxy(host: "pve.example.com", port: 3128))
        XCTAssertNil(SpiceProxy(url: ""))
    }

    func testConnectToDeadPortFails() async {
        // Nothing listening on this port → connect must fail, not hang.
        let conn = SpiceChannelConnection(
            host: "127.0.0.1", port: 1, useTLS: false, allowSelfSigned: false,
            channelType: .main, channelID: 0
        )
        do {
            _ = try await conn.connect(password: nil)
            XCTFail("expected connection failure")
        } catch {
            // expected
        }
        await conn.close()
    }
}
