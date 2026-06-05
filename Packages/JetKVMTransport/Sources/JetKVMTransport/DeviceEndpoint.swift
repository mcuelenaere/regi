import Foundation

/// Where on the network a JetKVM device lives. Owns URL construction so the
/// HTTP client and the WebSocket signaling client agree on the same scheme,
/// host and port.
public struct DeviceEndpoint: Sendable, Hashable {
    /// Hostname or IP literal. No scheme, no port, no brackets for IPv6 —
    /// we compose those at URL build time.
    public let host: String
    public let port: Int
    public let useTLS: Bool
    /// Reserved for future use. Asks `TLSDelegate` to override the system
    /// trust evaluation with `SecTrustSetExceptions` when set true.
    ///
    /// **Currently a no-op for the JetKVM default cert path on macOS 14+:**
    /// Apple's Network.framework BoringSSL fails the TLS handshake at
    /// `boringssl_session_set_peer_verification_state_from_session` before
    /// our delegate is invoked at all, so we never get a chance to
    /// override. Verified against M1 hardware — `[tls]` log category
    /// stays silent. The transport API still carries the flag because
    /// a) the current UI keeps it off, b) a future workaround
    /// (e.g. shipping the JetKVM CA in a custom trust store) would re-use
    /// this code path.
    public let allowSelfSignedCertificate: Bool
    /// Which device family this endpoint targets. Selects the transport
    /// backend in `Session`. Defaults to `.jetKVM` so existing call
    /// sites are unaffected.
    public let kind: DeviceKind
    /// Login username. JetKVM authenticates with a password only and
    /// ignores this; PiKVM requires it (defaults to `admin` at the
    /// App layer). `nil` for the JetKVM path.
    public let username: String?

    public init(
        host: String,
        port: Int = 80,
        useTLS: Bool = false,
        allowSelfSignedCertificate: Bool = false,
        kind: DeviceKind = .jetKVM,
        username: String? = nil
    ) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.allowSelfSignedCertificate = allowSelfSignedCertificate
        self.kind = kind
        self.username = username
    }

    public func httpURL(path: String, queryItems: [URLQueryItem]? = nil) -> URL {
        url(scheme: useTLS ? "https" : "http", path: path, queryItems: queryItems)
    }

    public func webSocketURL(path: String) -> URL {
        url(scheme: useTLS ? "wss" : "ws", path: path, queryItems: nil)
    }

    private func url(scheme: String, path: String, queryItems: [URLQueryItem]?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if shouldIncludePort {
            components.port = port
        }
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else {
            // The URLComponents path requires a leading slash. We control the
            // input here so this is a programming error if it fires.
            preconditionFailure("DeviceEndpoint produced an invalid URL: \(components)")
        }
        return url
    }

    private var shouldIncludePort: Bool {
        switch (useTLS, port) {
        case (true, 443), (false, 80): return false
        default: return true
        }
    }
}
