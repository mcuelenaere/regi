import Foundation
import KVMCore
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "http")

/// HTTP client for JetKVM's REST endpoints.
///
/// One client per device. Cookies are managed by URLSession's own
/// `HTTPCookieStorage` — `.ephemeral` URLSessionConfigurations ship a
/// fresh in-memory cookie storage per instance, scoped to that
/// session. `Set-Cookie` on responses is parsed and stored
/// automatically (with full RFC-6265 attributes); `Cookie` is
/// attached to subsequent requests for matching URLs without our
/// help. The same storage is exposed via `cookieStorage` so
/// `SignalingClient` can share it for the WebSocket upgrade.
public final class HTTPClient: @unchecked Sendable {
    public let endpoint: DeviceEndpoint
    public let urlSession: URLSession
    private let tlsDelegate: TLSDelegate

    private let encoder: JSONEncoder = JSONEncoder()
    private let decoder: JSONDecoder = JSONDecoder()

    /// Designated initializer. Public callers use the no-config
    /// overload; tests inject a `URLSessionConfiguration` with
    /// `protocolClasses = [MockURLProtocol.self]` so the round-trip
    /// can be verified without a real device.
    internal init(endpoint: DeviceEndpoint, configuration: URLSessionConfiguration) {
        self.endpoint = endpoint
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        let delegate = TLSDelegate(allowSelfSignedCertificate: endpoint.allowSelfSignedCertificate)
        self.tlsDelegate = delegate
        self.urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public convenience init(endpoint: DeviceEndpoint) {
        // `.ephemeral` returns a fresh per-call config with a
        // brand-new in-memory `HTTPCookieStorage`. Per-HTTPClient
        // scoping falls out naturally — no risk of leaking cookies
        // between sessions, no shared global state.
        self.init(endpoint: endpoint, configuration: .ephemeral)
    }

    /// The `HTTPCookieStorage` URLSession uses to capture and
    /// attach cookies for requests made through this client. Shared
    /// with `SignalingClient` (via `Session.connect`) so the WS
    /// upgrade carries the auth cookie URLSession captured here.
    public var cookieStorage: HTTPCookieStorage? {
        urlSession.configuration.httpCookieStorage
    }

    // MARK: - Endpoints

    /// `GET /device/status` — public endpoint, returns whether the device
    /// has been provisioned at all (`web.go:810-827`).
    public func getDeviceStatus() async throws -> DeviceStatus {
        try await get("/device/status")
    }

    /// `GET /device` — protected. In `noPassword` mode the protected
    /// middleware lets unauthenticated requests through (`web.go:561-577`)
    /// so this also acts as our way to read `authMode` without a cookie.
    /// Throws `.unauthorized` if password mode is on and we have no valid
    /// cookie yet.
    public func getDevice() async throws -> LocalDevice {
        try await get("/device")
    }

    /// `POST /auth/login-local` — public. On success the server's
    /// `Set-Cookie: authToken=<uuid>` is captured by URLSession into
    /// the session's `HTTPCookieStorage`; subsequent requests
    /// automatically include it via the `Cookie:` header.
    public func login(password: String) async throws {
        let url = endpoint.httpURL(path: "/auth/login-local")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try encoder.encode(LoginRequest(password: password))
        let (data, response) = try await rawCall(req)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }
        log.debug("login response status=\(httpResponse.statusCode, privacy: .public) headers=\(self.headerKeys(httpResponse), privacy: .public)")
        if !(200..<300).contains(httpResponse.statusCode) {
            throw mapError(statusCode: httpResponse.statusCode, headers: httpResponse.allHeaderFields, body: data)
        }
        log.debug("login OK")
    }

    // MARK: - Internal request plumbing

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = endpoint.httpURL(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        log.debug("GET \(url.absoluteString, privacy: .public)")
        return try await perform(req)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await performRaw(request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HTTPClientError.decoding(String(describing: error))
        }
    }

    private func performRaw(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await rawCall(request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapError(statusCode: http.statusCode, headers: http.allHeaderFields, body: data)
        }
        return data
    }

    private func rawCall(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await urlSession.data(for: request)
        } catch let urlErr as URLError where Self.isTLSTrustError(urlErr.code) {
            // System trust store rejected the cert chain and the user
            // hasn't opted into trusting it (allowSelfSignedCertificate
            // is false, or TLSDelegate fell through to default
            // handling). Surface as a distinct error so Session can
            // transition to .awaitingTrustOverride and the UI can
            // prompt the user.
            throw HTTPClientError.untrustedServerCertificate(
                reason: urlErr.localizedDescription
            )
        } catch {
            throw HTTPClientError.transport(String(describing: error))
        }
    }

    /// True for the URLError codes that mean "the TLS handshake's cert
    /// chain didn't pass system trust evaluation." We treat all of
    /// these the same — the user opt-in we'd offer (`SecTrustSet-
    /// Exceptions` via TLSDelegate) overrides chain-of-trust *and*
    /// hostname *and* validity-period checks anyway.
    private static func isTLSTrustError(_ code: URLError.Code) -> Bool {
        switch code {
        case .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate,
             .serverCertificateNotYetValid:
            return true
        default:
            return false
        }
    }

    // MARK: - Helpers

    private func headerKeys(_ response: HTTPURLResponse) -> String {
        response.allHeaderFields.keys.compactMap { $0 as? String }.joined(separator: ", ")
    }

    private func mapError(statusCode: Int, headers: [AnyHashable: Any], body: Data) -> HTTPClientError {
        let message = parseErrorMessage(body)
        switch statusCode {
        case 400: return .badRequest(message: message)
        case 401: return .unauthorized(message: message)
        case 404: return .notFound
        case 429:
            let retryAfter = (headers["Retry-After"] as? String).flatMap(Int.init) ?? 0
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .server(statusCode: statusCode, message: message)
        }
    }

    private func parseErrorMessage(_ body: Data) -> String? {
        struct Envelope: Decodable {
            let error: String?
            let message: String?
        }
        guard let env = try? decoder.decode(Envelope.self, from: body) else { return nil }
        return env.error ?? env.message
    }
}
