import XCTest
@testable import JetKVMTransport

/// Live handshake test against a real SPICE server (QEMU). Skipped unless
/// `SPICE_TEST_HOST` is set, so CI doesn't need QEMU. Run locally with e.g.:
///
///   qemu-system-x86_64 -spice port=5930,disable-ticketing=on \
///       -display none -vga qxl &
///   SPICE_TEST_HOST=127.0.0.1 SPICE_TEST_PORT=5930 \
///       swift test --filter SpiceHandshakeIntegrationTests
///
/// Proves the transport + link handshake + (empty) ticket auth against the
/// real spice-server, independent of any guest OS being booted.
final class SpiceHandshakeIntegrationTests: XCTestCase {

    private var host: String? { ProcessInfo.processInfo.environment["SPICE_TEST_HOST"] }
    private var port: UInt16 {
        UInt16(ProcessInfo.processInfo.environment["SPICE_TEST_PORT"] ?? "5930") ?? 5930
    }
    private var password: String? { ProcessInfo.processInfo.environment["SPICE_TEST_PASSWORD"] }

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
}
