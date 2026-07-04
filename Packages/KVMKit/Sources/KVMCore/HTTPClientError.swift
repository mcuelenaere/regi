import Foundation

/// HTTP errors surfaced by a backend's HTTP layer. JetKVM's login endpoint
/// distinguishes 400 (noPassword mode), 401 (bad password), and 429
/// (rate-limited); callers want to react differently to each, so we model them
/// explicitly. Lives in `KVMCore` because both `JetKVMKit`'s `HTTPClient` and
/// `PiKVMKit`'s `PiKVMHTTPClient` throw and pattern-match on it.
public enum HTTPClientError: Error, Sendable, Equatable {
    case unauthorized(message: String?)
    case badRequest(message: String?)
    case rateLimited(retryAfter: Int)
    case notFound
    case server(statusCode: Int, message: String?)
    case invalidResponse
    case decoding(String)
    case transport(String)
    /// TLS handshake completed but the server's certificate didn't
    /// pass the system trust store and the user hasn't opted into
    /// trusting it. The reason carries the system-localized message
    /// (e.g. "certificate is not trusted") for display.
    case untrustedServerCertificate(reason: String)
}
