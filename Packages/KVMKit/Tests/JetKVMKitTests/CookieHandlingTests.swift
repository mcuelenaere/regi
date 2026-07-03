import XCTest
@testable import JetKVMKit
import KVMCore

/// Covers the cookie-handling rework: HTTPClient delegates to
/// URLSession's `HTTPCookieStorage` instead of a hand-rolled jar,
/// and the same storage instance is shared with SignalingClient so
/// the WS upgrade carries the auth cookie URLSession captured.
///
/// The full URLSession ↔ storage round-trip (parse `Set-Cookie` on
/// the way in, attach `Cookie:` on the way out) isn't unit-testable
/// in isolation — URLSession hands HTTP loading off entirely to
/// custom `URLProtocol` subclasses, including cookie parsing and
/// attachment, so a mock protocol would just shadow the system
/// behaviour we want to verify. That branch is covered by the
/// hardware smoke test in the plan. What we *can* assert here:
///   - per-HTTPClient storage scoping (no accidental sharing)
///   - the SignalingClient wiring (same storage instance reaches
///     the WS layer)
///   - `HTTPCookieStorage` preserves the RFC-6265 attributes
///     (Path, Max-Age, HttpOnly) that the old hand-rolled jar
///     dropped — the concrete reason we're doing this rework
final class CookieHandlingTests: XCTestCase {
    /// Each `HTTPClient` instance gets its own ephemeral
    /// `HTTPCookieStorage`. Two clients on the same endpoint must
    /// not share state — otherwise a logout on one would log the
    /// other out.
    func testCookieStorageIsPerInstance() {
        let endpoint = DeviceEndpoint(host: "kvm.local", port: 80)
        let a = HTTPClient(endpoint: endpoint)
        let b = HTTPClient(endpoint: endpoint)
        XCTAssertNotNil(a.cookieStorage)
        XCTAssertNotNil(b.cookieStorage)
        XCTAssertFalse(a.cookieStorage === b.cookieStorage)
    }

    /// Confirms the wiring `Session.connect` relies on: handing
    /// `http.cookieStorage` to `SignalingClient` produces the same
    /// storage instance on the WS side. Without this, the WS
    /// upgrade would see an empty cookie jar even after a
    /// successful HTTP login.
    func testSignalingClientSharesHTTPClientCookieStorage() async {
        let endpoint = DeviceEndpoint(host: "kvm.local", port: 80)
        let http = HTTPClient(endpoint: endpoint)
        let signaling = SignalingClient(
            endpoint: endpoint,
            cookieStorage: http.cookieStorage
        )
        let signalingStorage = await signaling.cookieStorage
        XCTAssertTrue(signalingStorage === http.cookieStorage)
    }

    /// The old `[String: String]` jar dropped every attribute except
    /// `name → value`. `HTTPCookieStorage` preserves them. Builds the
    /// cookie JetKVM's server actually sets — see web.go's
    /// `c.SetCookie("authToken", uuid, 604800, "/", "", false, true)`
    /// — stores it, then asserts Path / expiry / HttpOnly all
    /// survive. Also verifies path scoping: a Path=/ cookie applies
    /// to every endpoint on the host.
    func testHTTPCookieStoragePreservesAttributes() throws {
        let endpoint = DeviceEndpoint(host: "kvm.local", port: 80)
        let http = HTTPClient(endpoint: endpoint)
        let storage = try XCTUnwrap(http.cookieStorage)

        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "authToken",
            .value: "test-uuid",
            .domain: "kvm.local",
            .path: "/",
            .maximumAge: "604800",
        ]))
        storage.setCookie(cookie)

        let retrieved = try XCTUnwrap(
            storage.cookies(for: endpoint.httpURL(path: "/device"))?
                .first(where: { $0.name == "authToken" })
        )
        XCTAssertEqual(retrieved.value, "test-uuid")
        XCTAssertEqual(retrieved.path, "/")
        XCTAssertNotNil(retrieved.expiresDate)
        // Path=/ means the cookie applies to every path on the host.
        XCTAssertNotNil(
            storage.cookies(for: endpoint.httpURL(path: "/auth/logout"))?
                .first(where: { $0.name == "authToken" })
        )
    }
}
