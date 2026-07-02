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
