import KVMCore
import Foundation
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "pikvm-http")

/// HTTP client for PiKVM's KVMD auth endpoints. One per device. Shares
/// `HTTPTransport` with the JetKVM path, so the ephemeral session, the
/// `auth_token` cookie capture and the self-signed-cert handling behave
/// identically and the App layer's `.awaitingTrustOverride` flow works
/// unchanged. That same storage is shared with the Janus and `/api/ws`
/// WebSocket clients so their upgrades carry the cookie (nginx auth-gates
/// both).
public final class PiKVMHTTPClient: @unchecked Sendable {
    private let transport: HTTPTransport

    public init(endpoint: DeviceEndpoint) {
        self.transport = HTTPTransport(endpoint: endpoint)
    }

    public var endpoint: DeviceEndpoint { transport.endpoint }

    /// Shared with the WebSocket clients so their upgrades carry the
    /// `auth_token` cookie URLSession captured on login.
    public var cookieStorage: HTTPCookieStorage? { transport.cookieStorage }

    /// `POST /api/auth/login` — form-encoded `user`/`passwd`. On 200 the
    /// server's `Set-Cookie: auth_token=…` is captured automatically;
    /// 403 means bad credentials.
    public func login(user: String, password: String) async throws {
        var req = URLRequest(url: endpoint.httpURL(path: "/api/auth/login"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formBody(["user": user, "passwd": password])
        let (data, http) = try await transport.call(req)
        log.debug("login status=\(http.statusCode, privacy: .public)")
        guard (200..<300).contains(http.statusCode) else {
            // KVMD returns 403 for bad credentials (no WWW-Authenticate).
            if http.statusCode == 403 {
                throw HTTPClientError.unauthorized(message: Self.message(data))
            }
            throw HTTPClientError.server(statusCode: http.statusCode, message: Self.message(data))
        }
    }

    // MARK: - Internal

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
}
