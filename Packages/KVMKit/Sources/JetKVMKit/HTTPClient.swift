import Foundation
import KVMCore
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "http")

/// HTTP client for JetKVM's REST endpoints.
///
/// One client per device. The session, its cookie storage and the TLS-trust
/// handling live in `HTTPTransport`; `Set-Cookie` on responses is parsed and
/// stored automatically (with full RFC-6265 attributes) and `Cookie` is
/// attached to subsequent requests for matching URLs without our help. The
/// same storage is exposed via `cookieStorage` so `SignalingClient` can share
/// it for the WebSocket upgrade.
public final class HTTPClient: @unchecked Sendable {
    private let transport: HTTPTransport

    private let encoder: JSONEncoder = JSONEncoder()
    private let decoder: JSONDecoder = JSONDecoder()

    public init(endpoint: DeviceEndpoint) {
        self.transport = HTTPTransport(endpoint: endpoint)
    }

    public var endpoint: DeviceEndpoint { transport.endpoint }

    /// The `HTTPCookieStorage` URLSession uses to capture and
    /// attach cookies for requests made through this client. Shared
    /// with `SignalingClient` (via `Session.connect`) so the WS
    /// upgrade carries the auth cookie URLSession captured here.
    public var cookieStorage: HTTPCookieStorage? { transport.cookieStorage }

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
        var req = URLRequest(url: endpoint.httpURL(path: "/auth/login-local"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try encoder.encode(LoginRequest(password: password))
        let (data, http) = try await transport.call(req)
        log.debug("login response status=\(http.statusCode, privacy: .public) headers=\(self.headerKeys(http), privacy: .public)")
        if !(200..<300).contains(http.statusCode) {
            throw mapError(statusCode: http.statusCode, headers: http.allHeaderFields, body: data)
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
        let (data, http) = try await transport.call(req)
        guard (200..<300).contains(http.statusCode) else {
            throw mapError(statusCode: http.statusCode, headers: http.allHeaderFields, body: data)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HTTPClientError.decoding(String(describing: error))
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
