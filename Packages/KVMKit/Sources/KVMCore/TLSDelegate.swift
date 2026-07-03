import Foundation
import OSLog
import Security

private let log = Logger(subsystem: "app.regi.mac", category: "tls")

/// `URLSessionDelegate` that optionally trusts any server certificate
/// presented during the TLS handshake. Reserved for future use — at the
/// time of writing this delegate is *never invoked* for JetKVM's default
/// self-signed cert chain on macOS 14+, because Apple's
/// Network.framework BoringSSL fails to extract the peer certificates
/// from the SSL session before the cert-verification callback can hand
/// off to URLSession's delegate. See the comment on
/// `DeviceEndpoint.allowSelfSignedCertificate` for the broader context.
///
/// We keep the delegate around because it correctly handles the
/// uncommon case of a JetKVM behind a reverse proxy with a real
/// (CA-issued) cert when `allowSelfSignedCertificate` is left false —
/// it falls through to default handling and the connection succeeds
/// against the system trust store.
package final class TLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    package let allowSelfSignedCertificate: Bool

    package init(allowSelfSignedCertificate: Bool) {
        self.allowSelfSignedCertificate = allowSelfSignedCertificate
    }

    // Session-level challenges (rare for TLS — usually fires task-level).
    package func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge: challenge, level: "session", completionHandler: completionHandler)
    }

    // Task-level challenges (HTTPS server trust normally fires here).
    package func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge: challenge, level: "task", completionHandler: completionHandler)
    }

    private func handle(
        challenge: URLAuthenticationChallenge,
        level: String,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        log.debug("\(level)-level challenge: method=\(method, privacy: .public) host=\(challenge.protectionSpace.host, privacy: .public) allow=\(self.allowSelfSignedCertificate, privacy: .public)")

        guard method == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard allowSelfSignedCertificate else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 1. Try evaluating; if it fails, copy the failure as exceptions
        //    onto the trust object so subsequent evaluation passes.
        var error: CFError?
        let initialOk = SecTrustEvaluateWithError(serverTrust, &error)
        if !initialOk {
            log.debug("initial trust evaluation failed: \(error?.localizedDescription ?? "?", privacy: .public) — installing exceptions")
            if let exceptions = SecTrustCopyExceptions(serverTrust) {
                SecTrustSetExceptions(serverTrust, exceptions)
            }
        }

        // 2. Hand URLSession a credential built from the (now-accepted)
        //    trust object. This bypasses both cert validity and hostname
        //    checks — that's the user's explicit opt-in.
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
