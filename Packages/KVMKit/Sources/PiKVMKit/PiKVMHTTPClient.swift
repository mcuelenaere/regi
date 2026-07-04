import KVMCore
import Foundation
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "pikvm-http")

/// HTTP client for PiKVM's KVMD auth endpoints. One per device. Like
/// `HTTPClient`, it uses an ephemeral `URLSession` whose
/// `HTTPCookieStorage` captures the `auth_token` cookie on login; that
/// same storage is shared with the Janus and `/api/ws` WebSocket clients
/// so their upgrades carry the cookie (nginx auth-gates both).
///
/// Reuses `HTTPClientError` and the TLS-trust handling from the JetKVM
/// path so the App layer's `.awaitingTrustOverride` flow works
/// unchanged for self-signed PiKVM certs.
public final class PiKVMHTTPClient: @unchecked Sendable {
    public let endpoint: DeviceEndpoint
    public let urlSession: URLSession
    private let tlsDelegate: TLSDelegate

    internal init(endpoint: DeviceEndpoint, configuration: URLSessionConfiguration) {
        self.endpoint = endpoint
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        let delegate = TLSDelegate(allowSelfSignedCertificate: endpoint.allowSelfSignedCertificate)
        self.tlsDelegate = delegate
        self.urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public convenience init(endpoint: DeviceEndpoint) {
        self.init(endpoint: endpoint, configuration: .ephemeral)
    }

    /// Shared with the WebSocket clients so their upgrades carry the
    /// `auth_token` cookie URLSession captured on login.
    public var cookieStorage: HTTPCookieStorage? {
        urlSession.configuration.httpCookieStorage
    }

    /// `POST /api/auth/login` — form-encoded `user`/`passwd`. On 200 the
    /// server's `Set-Cookie: auth_token=…` is captured automatically;
    /// 403 means bad credentials.
    public func login(user: String, password: String) async throws {
        let url = endpoint.httpURL(path: "/api/auth/login")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formBody(["user": user, "passwd": password])
        let (data, response) = try await rawCall(req)
        guard let http = response as? HTTPURLResponse else { throw HTTPClientError.invalidResponse }
        log.debug("login status=\(http.statusCode, privacy: .public)")
        guard (200..<300).contains(http.statusCode) else {
            // KVMD returns 403 for bad credentials (no WWW-Authenticate).
            if http.statusCode == 403 {
                throw HTTPClientError.unauthorized(message: Self.message(data))
            }
            throw HTTPClientError.server(statusCode: http.statusCode, message: Self.message(data))
        }
    }

    /// `GET /api/auth/check` — 200 once authenticated (the cookie is
    /// attached automatically). Throws `.unauthorized` on 401/403.
    public func checkAuth() async throws {
        let url = endpoint.httpURL(path: "/api/auth/check")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, response) = try await rawCall(req)
        guard let http = response as? HTTPURLResponse else { throw HTTPClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw HTTPClientError.unauthorized(message: Self.message(data))
            }
            throw HTTPClientError.server(statusCode: http.statusCode, message: Self.message(data))
        }
    }

    // MARK: - Internal

    private func rawCall(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await urlSession.data(for: request)
        } catch let urlErr as URLError where Self.isTLSTrustError(urlErr.code) {
            throw HTTPClientError.untrustedServerCertificate(reason: urlErr.localizedDescription)
        } catch {
            throw HTTPClientError.transport(String(describing: error))
        }
    }

    static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let encoded = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func message(_ body: Data) -> String? {
        struct Envelope: Decodable { let result: Result?; struct Result: Decodable { let error: String? } }
        if let env = try? JSONDecoder().decode(Envelope.self, from: body), let e = env.result?.error {
            return e
        }
        return String(data: body, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
    }

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
}
