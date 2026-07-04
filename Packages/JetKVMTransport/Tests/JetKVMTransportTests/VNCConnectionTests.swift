import XCTest
@testable import JetKVMTransport

final class VNCConnectionTests: XCTestCase {
    func testNoneAuthHandshake() async throws {
        var cfg = FakeRFBServer.Config()
        cfg.securityTypes = [1]
        cfg.width = 800; cfg.height = 600; cfg.name = "desktop"
        let server = try FakeRFBServer(config: cfg)
        let port = try await server.start()
        defer { server.stop() }

        let conn = VNCConnection(host: "127.0.0.1", port: port)
        try await conn.open()
        let init0 = try await conn.handshake(password: nil)
        XCTAssertEqual(init0.width, 800)
        XCTAssertEqual(init0.height, 600)
        XCTAssertEqual(init0.name, "desktop")
        XCTAssertEqual(init0.pixelFormat, .bgra32)

        let outcome = await server.result()
        XCTAssertEqual(outcome.chosenSecurity, 1)
        XCTAssertEqual(outcome.clientShared, 1)
        await conn.close()
    }

    func testVNCAuthSuccess() async throws {
        var cfg = FakeRFBServer.Config()
        cfg.securityTypes = [2]
        cfg.expectedPassword = "letmein"
        let server = try FakeRFBServer(config: cfg)
        let port = try await server.start()
        defer { server.stop() }

        let conn = VNCConnection(host: "127.0.0.1", port: port)
        try await conn.open()
        _ = try await conn.handshake(password: "letmein")

        let outcome = await server.result()
        XCTAssertEqual(outcome.chosenSecurity, 2)
        XCTAssertEqual(outcome.authAccepted, true)
        await conn.close()
    }

    func testVNCAuthWrongPasswordThrows() async throws {
        var cfg = FakeRFBServer.Config()
        cfg.securityTypes = [2]
        cfg.expectedPassword = "correct"
        let server = try FakeRFBServer(config: cfg)
        let port = try await server.start()
        defer { server.stop() }

        let conn = VNCConnection(host: "127.0.0.1", port: port)
        try await conn.open()
        do {
            _ = try await conn.handshake(password: "wrong")
            XCTFail("expected auth failure")
        } catch let error as VNCConnectionError {
            guard case .authFailed = error else {
                return XCTFail("expected .authFailed, got \(error)")
            }
        }
        await conn.close()
    }

    func testVNCAuthWithoutPasswordRequiresPassword() async throws {
        var cfg = FakeRFBServer.Config()
        cfg.securityTypes = [2]
        let server = try FakeRFBServer(config: cfg)
        let port = try await server.start()
        defer { server.stop() }

        let conn = VNCConnection(host: "127.0.0.1", port: port)
        try await conn.open()
        do {
            _ = try await conn.handshake(password: nil)
            XCTFail("expected password-required failure")
        } catch let error as VNCConnectionError {
            XCTAssertEqual(error, .authFailed("password required"))
        }
        await conn.close()
    }

    func testUnsupportedVersionThrows() async throws {
        var cfg = FakeRFBServer.Config()
        cfg.version = "RFB 003.003\n"
        let server = try FakeRFBServer(config: cfg)
        let port = try await server.start()
        defer { server.stop() }

        let conn = VNCConnection(host: "127.0.0.1", port: port)
        try await conn.open()
        do {
            _ = try await conn.handshake(password: nil)
            XCTFail("expected version rejection")
        } catch let error as VNCConnectionError {
            guard case .unsupportedVersion = error else {
                return XCTFail("expected .unsupportedVersion, got \(error)")
            }
        }
        await conn.close()
    }

    func testSecurityRefusalReason() async throws {
        var cfg = FakeRFBServer.Config()
        cfg.securityTypes = []
        cfg.refusalReason = "too many connections"
        let server = try FakeRFBServer(config: cfg)
        let port = try await server.start()
        defer { server.stop() }

        let conn = VNCConnection(host: "127.0.0.1", port: port)
        try await conn.open()
        do {
            _ = try await conn.handshake(password: nil)
            XCTFail("expected handshake failure")
        } catch let error as VNCConnectionError {
            XCTAssertEqual(error, .handshakeFailed("too many connections"))
        }
        await conn.close()
    }

    func testUnsupportedSecurityTypeThrows() async throws {
        var cfg = FakeRFBServer.Config()
        cfg.securityTypes = [19] // VeNCrypt — unsupported
        let server = try FakeRFBServer(config: cfg)
        let port = try await server.start()
        defer { server.stop() }

        let conn = VNCConnection(host: "127.0.0.1", port: port)
        try await conn.open()
        do {
            _ = try await conn.handshake(password: nil)
            XCTFail("expected unsupported-security failure")
        } catch let error as VNCConnectionError {
            guard case .handshakeFailed = error else {
                return XCTFail("expected .handshakeFailed, got \(error)")
            }
        }
        await conn.close()
    }

    func testConnectToDeadPortFails() async {
        let conn = VNCConnection(host: "127.0.0.1", port: 1)
        do {
            try await conn.open()
            XCTFail("expected connection failure")
        } catch {
            // expected
        }
        await conn.close()
    }
}
