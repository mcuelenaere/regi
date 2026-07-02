import XCTest
@testable import JetKVMTransport

/// Live handshake/session tests against a real SPICE server. Both are skipped
/// unless the relevant env var is set, so CI needs no server.
///
/// Plain qemu/libvirt:
///   qemu-system-x86_64 -spice port=5930,disable-ticketing=on -display none -vga qxl &
///   SPICE_TEST_HOST=127.0.0.1 SPICE_TEST_PORT=5930 swift test --filter SpiceHandshakeIntegrationTests
///
/// Proxmox (generate a FRESH .vv from the UI first — the ticket is one-time
/// and short-lived; this Mac must be able to reach the node's tls-port
/// directly, as the HTTP-CONNECT proxy tunnel isn't implemented yet):
///   SPICE_TEST_VV=/path/to/console.vv swift test --filter SpiceHandshakeIntegrationTests
///
/// A pass proves transport + link + ticket auth + framing/flow-control +
/// main INIT. There is no video yet (display channel pending).
final class SpiceHandshakeIntegrationTests: XCTestCase {

    private var host: String? { ProcessInfo.processInfo.environment["SPICE_TEST_HOST"] }
    private var port: UInt16 {
        UInt16(ProcessInfo.processInfo.environment["SPICE_TEST_PORT"] ?? "5930") ?? 5930
    }
    private var password: String? { ProcessInfo.processInfo.environment["SPICE_TEST_PASSWORD"] }
    private var vvPath: String? { ProcessInfo.processInfo.environment["SPICE_TEST_VV"] }

    func testMainChannelLinkAndAuth() async throws {
        try XCTSkipUnless(host != nil, "set SPICE_TEST_HOST to run the live handshake test")
        let conn = SpiceChannelConnection(
            host: host!, port: port, useTLS: false, allowSelfSigned: false,
            channelType: .main, channelID: 0
        )
        let reply = try await conn.connect(password: password)
        XCTAssertEqual(reply.error, SpiceProtocol.LinkErr.ok.rawValue)
        XCTAssertEqual(reply.pubKey.count, SpiceProtocol.ticketPubkeyBytes)
        await conn.close()
    }

    func testProxmoxLiveSessionFromVV() async throws {
        try XCTSkipUnless(vvPath != nil, "set SPICE_TEST_VV to a fresh Proxmox .vv path")
        let text = try String(contentsOfFile: vvPath!, encoding: .utf8)
        let cfg = SpiceVVConfig.parse(text)
        if cfg.proxy != nil {
            print("note: .vv has a proxy=\(cfg.proxy!); direct connection assumed (proxy tunnel not implemented)")
        }
        let ep = try cfg.resolvedEndpoint()

        let conn = SpiceChannelConnection(
            host: ep.host, port: ep.port, useTLS: ep.useTLS, allowSelfSigned: false,
            channelType: .main, channelID: 0,
            tlsConfig: SpiceTLSConfig(caPEM: cfg.caPEM, hostSubject: cfg.hostSubject)
        )
        let reply = try await conn.connect(password: cfg.password)
        XCTAssertEqual(reply.error, SpiceProtocol.LinkErr.ok.rawValue, "link + ticket auth")

        // Pump the main channel and wait for INIT.
        let main = SpiceMainChannel(connection: conn)
        let info = try await Self.withTimeout(seconds: 10) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SpiceMsgMainInit, Error>) in
                main.onInit = { info in cont.resume(returning: info) }
                main.start()
            }
        }
        // The server always supports at least server (relative) mouse mode.
        XCTAssertNotEqual(info.supportedMouseModes, 0, "received a valid MAIN_INIT")
        main.stop()
        await conn.close()
    }

    /// Race an async operation against a timeout so a stuck server can't hang
    /// the test indefinitely.
    private static func withTimeout<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SpiceConnectionError.protocolError("timed out after \(seconds)s")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
