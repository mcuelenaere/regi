import Foundation

/// The URLSession plumbing every device HTTP client needs, so `HTTPClient`
/// (JetKVM) and `PiKVMHTTPClient` don't each carry a copy: an ephemeral
/// session, the self-signed-cert opt-in, and the one error distinction the
/// App layer's `.awaitingTrustOverride` flow depends on.
///
/// One transport per device. `.ephemeral` returns a fresh config with a
/// brand-new in-memory `HTTPCookieStorage`, so per-connection cookie scoping
/// falls out naturally — no shared global state, nothing leaking between
/// sessions.
public final class HTTPTransport: @unchecked Sendable {
    public let endpoint: DeviceEndpoint

    private let urlSession: URLSession
    private let tlsDelegate: TLSDelegate

    public init(endpoint: DeviceEndpoint) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        let delegate = TLSDelegate(allowSelfSignedCertificate: endpoint.allowSelfSignedCertificate)
        self.tlsDelegate = delegate
        self.urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// The storage URLSession captures `Set-Cookie` into and attaches `Cookie`
    /// from. Handed to the WebSocket clients so their upgrades carry the auth
    /// cookie this transport's login captured.
    public var cookieStorage: HTTPCookieStorage? {
        urlSession.configuration.httpCookieStorage
    }

    /// Perform `request`, mapping transport-level failures onto
    /// `HTTPClientError`. Status codes are the caller's business — each
    /// device's API assigns them different meanings.
    public func call(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let urlErr as URLError where Self.isTLSTrustError(urlErr.code) {
            // System trust store rejected the cert chain and the user hasn't
            // opted into trusting it (allowSelfSignedCertificate is false, or
            // TLSDelegate fell through to default handling). Surface as a
            // distinct error so the backend can transition to
            // .awaitingTrustOverride and the UI can prompt.
            throw HTTPClientError.untrustedServerCertificate(reason: urlErr.localizedDescription)
        } catch {
            throw HTTPClientError.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }
        return (data, http)
    }

    /// True for the URLError codes that mean "the TLS handshake's cert chain
    /// didn't pass system trust evaluation." We treat all of these the same —
    /// the user opt-in we'd offer (`SecTrustSetExceptions` via TLSDelegate)
    /// overrides chain-of-trust *and* hostname *and* validity-period checks
    /// anyway.
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
