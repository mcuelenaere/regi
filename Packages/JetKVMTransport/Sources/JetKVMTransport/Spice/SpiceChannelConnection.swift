import Foundation
import Network
import OSLog
import Security

private let log = Logger(subsystem: "app.regi.mac", category: "spice-conn")

/// TLS trust configuration for a SPICE connection. For Proxmox this comes
/// from the `.vv` file: `caPEM` is the cluster CA to anchor trust to, and
/// `hostSubject` the expected certificate subject.
struct SpiceTLSConfig: Sendable {
    var caPEM: String?
    var hostSubject: String?
}

/// An HTTP CONNECT proxy (Proxmox `spiceproxy`), parsed from the `.vv`
/// `proxy=http://host:port` field.
struct SpiceProxy: Sendable, Equatable {
    var host: String
    var port: UInt16

    init(host: String, port: UInt16) { self.host = host; self.port = port }

    /// Parse `http://host:port` (scheme optional; default port 3128).
    init?(url: String) {
        var s = url
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        let parts = s.split(separator: ":", maxSplits: 1)
        guard let h = parts.first, !h.isEmpty else { return nil }
        self.host = String(h)
        self.port = parts.count > 1 ? (UInt16(parts[1]) ?? 3128) : 3128
    }
}

/// Errors surfaced by a SPICE channel connection. `.authFailed` maps to the
/// App layer's password prompt; `.untrustedCertificate` to the trust-override
/// prompt (mirroring the JetKVM/PiKVM flows).
enum SpiceConnectionError: Error, Equatable {
    case connectionFailed(String)
    case connectionClosed
    case linkRejected(SpiceProtocol.LinkErr)
    case authFailed
    case untrustedCertificate(String)
    case protocolError(String)
}

/// One SPICE channel's TCP/TLS connection: performs the link handshake +
/// ticket auth, then carries framed data messages. SPICE opens one of these
/// per channel (main, display, inputs, cursor); they share the connection id
/// the main channel establishes.
///
/// An `actor` so the send-serial counter and socket access are isolated; the
/// backend drives it from the main actor via `await`.
actor SpiceChannelConnection {
    let channelType: SpiceProtocol.ChannelType
    let channelID: UInt8

    private let host: String
    private let port: UInt16
    private let useTLS: Bool
    private let allowSelfSigned: Bool
    private let tlsConfig: SpiceTLSConfig?
    private let proxy: SpiceProxy?

    private var connection: NWConnection?
    private var sendSerial: UInt64 = 1

    /// Negotiated after the handshake.
    private(set) var useMiniHeader = false
    private(set) var connectionID: UInt32 = 0

    init(host: String, port: UInt16, useTLS: Bool, allowSelfSigned: Bool,
         channelType: SpiceProtocol.ChannelType, channelID: UInt8,
         connectionID: UInt32 = 0, tlsConfig: SpiceTLSConfig? = nil,
         proxy: SpiceProxy? = nil) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.allowSelfSigned = allowSelfSigned
        self.tlsConfig = tlsConfig
        self.proxy = proxy
        self.channelType = channelType
        self.channelID = channelID
        self.connectionID = connectionID
    }

    // MARK: - Handshake

    /// Connect the socket, run the link handshake and ticket auth. Returns the
    /// server's link reply (its caps + pubkey). `password` may be nil/empty —
    /// SPICE still expects an encrypted (empty) ticket.
    @discardableResult
    func connect(password: String?) async throws -> SpiceLinkReply {
        try await openSocket()

        // 1. Client link message. Advertise auth-selection, spice ticket auth
        //    and the mini header.
        let client = SpiceLinkClientMessage(
            connectionID: connectionID,
            channelType: channelType,
            channelID: channelID,
            commonCaps: SpiceCaps(bits: [
                SpiceProtocol.CommonCap.protocolAuthSelection.rawValue,
                SpiceProtocol.CommonCap.authSpice.rawValue,
                SpiceProtocol.CommonCap.miniHeader.rawValue,
            ]),
            channelCaps: SpiceCaps()
        )
        try await sendRaw(client.encode())

        // 2. Read the reply header + body.
        let headerData = try await receiveExactly(SpiceLinkHeader.byteCount)
        let header = try SpiceLinkHeader.parse(headerData)
        let body = try await receiveExactly(Int(header.size))
        let reply = try SpiceLinkReply.parse(body)

        guard let err = SpiceProtocol.LinkErr(rawValue: reply.error), err == .ok else {
            let e = SpiceProtocol.LinkErr(rawValue: reply.error) ?? .error
            throw SpiceConnectionError.linkRejected(e)
        }

        useMiniHeader = reply.commonCaps.has(SpiceProtocol.CommonCap.miniHeader.rawValue)
        let authSelection = reply.commonCaps.has(SpiceProtocol.CommonCap.protocolAuthSelection.rawValue)

        // 3. Ticket auth.
        if authSelection {
            var w = SpiceByteWriter()
            w.writeU32(SpiceProtocol.authMechanismSpice)
            try await sendRaw(w.data)
        }
        let ticket = try SpiceTicket.encrypt(password: password ?? "", derPublicKey: reply.pubKey)
        try await sendRaw(Data(ticket))

        // 4. Auth result.
        let resultData = try await receiveExactly(4)
        var r = SpiceByteReader(resultData)
        let result = try r.readU32()
        guard let rerr = SpiceProtocol.LinkErr(rawValue: result), rerr == .ok else {
            if result == SpiceProtocol.LinkErr.permissionDenied.rawValue {
                throw SpiceConnectionError.authFailed
            }
            throw SpiceConnectionError.linkRejected(SpiceProtocol.LinkErr(rawValue: result) ?? .error)
        }

        log.debug("SPICE channel \(self.channelType.rawValue)/\(self.channelID) linked (mini=\(self.useMiniHeader))")
        return reply
    }

    // MARK: - Data messages

    /// Send a framed channel message.
    func send(type: UInt16, payload: Data) async throws {
        var frame = SpiceByteWriter()
        if useMiniHeader {
            frame.writeBytes(SpiceMiniDataHeader(type: type, size: UInt32(payload.count)).encode())
        } else {
            frame.writeBytes(SpiceDataHeader(
                serial: sendSerial, type: type, size: UInt32(payload.count), subList: 0
            ).encode())
            sendSerial += 1
        }
        frame.writeBytes(payload)
        try await sendRaw(frame.data)
    }

    /// Read one framed channel message.
    func receive() async throws -> (type: UInt16, payload: Data) {
        if useMiniHeader {
            let h = try SpiceMiniDataHeader.parse(try await receiveExactly(SpiceMiniDataHeader.byteCount))
            let payload = h.size > 0 ? try await receiveExactly(Int(h.size)) : Data()
            return (h.type, payload)
        } else {
            let h = try SpiceDataHeader.parse(try await receiveExactly(SpiceDataHeader.byteCount))
            let payload = h.size > 0 ? try await receiveExactly(Int(h.size)) : Data()
            return (h.type, payload)
        }
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - Socket

    /// TLS options with a verify block that anchors trust to the `.vv` CA
    /// (when present) and does a soft host-subject check; falls back to
    /// accepting self-signed when the user opted in. SNI is set to the
    /// expected cert CN since the SPICE `host` may be an opaque proxy token.
    private func makeTLSOptions() -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        if let cn = Self.commonName(fromSubject: tlsConfig?.hostSubject) {
            sec_protocol_options_set_tls_server_name(sec, cn)
        }
        let anchors = tlsConfig?.caPEM.flatMap { Self.certificates(fromPEM: $0) }
        let expectedSubject = tlsConfig?.hostSubject
        let allow = allowSelfSigned
        guard anchors != nil || allow else { return tls }
        sec_protocol_options_set_verify_block(
            sec,
            { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                if let anchors, !anchors.isEmpty {
                    SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                    SecTrustSetAnchorCertificatesOnly(trust, true)
                }
                var evalError: CFError?
                if SecTrustEvaluateWithError(trust, &evalError) {
                    if let expectedSubject { Self.warnIfSubjectMismatch(trust, expected: expectedSubject) }
                    complete(true)
                } else if allow {
                    complete(true)   // user opted into trusting self-signed
                } else {
                    log.notice("SPICE TLS trust evaluation failed: \(String(describing: evalError), privacy: .public)")
                    complete(false)
                }
            },
            DispatchQueue.global()
        )
        return tls
    }

    private func openSocket() async throws {
        let params: NWParameters
        let endpointHost: String
        let endpointPort: UInt16

        if let proxy {
            // TCP to the proxy; the framer CONNECTs to host:port; TLS (if any)
            // runs over the tunnel. Framer goes *below* TLS in the stack.
            params = useTLS
                ? NWParameters(tls: makeTLSOptions(), tcp: NWProtocolTCP.Options())
                : NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
            let framer = NWProtocolFramer.Options(definition: SpiceProxyTunnel.definition)
            params.defaultProtocolStack.applicationProtocols.append(framer)
            SpiceProxyTunnel.enqueueTarget("\(host):\(port)")
            endpointHost = proxy.host
            endpointPort = proxy.port
        } else if useTLS {
            params = NWParameters(tls: makeTLSOptions())
            endpointHost = host
            endpointPort = port
        } else {
            params = NWParameters.tcp
            endpointHost = host
            endpointPort = port
        }

        guard let nwPort = NWEndpoint.Port(rawValue: endpointPort) else {
            throw SpiceConnectionError.connectionFailed("invalid port \(endpointPort)")
        }
        let conn = NWConnection(host: NWEndpoint.Host(endpointHost), port: nwPort, using: params)
        connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            let resumeOnce: (Result<Void, Error>) -> Void = { result in
                if !resumed { resumed = true; cont.resume(with: result) }
            }
            // Fail the connect if it neither succeeds nor errors in time
            // (e.g. a proxy that accepts the socket but never answers CONNECT).
            let timeout = DispatchWorkItem { conn.cancel() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timeout.cancel()
                    resumeOnce(.success(()))
                case .waiting(let error):
                    // Network.framework parks unreachable/refused connections
                    // in `.waiting` and retries indefinitely. Fail fast.
                    timeout.cancel()
                    resumeOnce(.failure(SpiceConnectionError.connectionFailed("\(error)")))
                case .failed(let error):
                    timeout.cancel()
                    resumeOnce(.failure(SpiceConnectionError.connectionFailed("\(error)")))
                case .cancelled:
                    resumeOnce(.failure(SpiceConnectionError.connectionFailed("connect timed out or closed")))
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
    }

    private func sendRaw(_ data: Data) async throws {
        guard let conn = connection else { throw SpiceConnectionError.connectionClosed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: SpiceConnectionError.connectionFailed("\(error)")) }
                else { cont.resume() }
            })
        }
    }

    /// Receive exactly `n` bytes or throw. `n == 0` returns empty.
    private func receiveExactly(_ n: Int) async throws -> Data {
        guard n > 0 else { return Data() }
        guard let conn = connection else { throw SpiceConnectionError.connectionClosed }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { content, _, isComplete, error in
                if let error {
                    cont.resume(throwing: SpiceConnectionError.connectionFailed("\(error)"))
                    return
                }
                if let content, content.count == n {
                    cont.resume(returning: content)
                } else if isComplete {
                    cont.resume(throwing: SpiceConnectionError.connectionClosed)
                } else {
                    cont.resume(throwing: SpiceConnectionError.protocolError("short read: got \(content?.count ?? 0)/\(n)"))
                }
            }
        }
    }

    // MARK: - TLS helpers

    /// Parse a PEM bundle into `SecCertificate`s (one per CERTIFICATE block).
    static func certificates(fromPEM pem: String) -> [SecCertificate]? {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var certs: [SecCertificate] = []
        var search = pem[...]
        while let b = search.range(of: begin), let e = search.range(of: end) {
            let base64 = search[b.upperBound..<e.lowerBound]
                .components(separatedBy: .whitespacesAndNewlines).joined()
            if let der = Data(base64Encoded: base64),
               let cert = SecCertificateCreateWithData(nil, der as CFData) {
                certs.append(cert)
            }
            search = search[e.upperBound...]
        }
        return certs.isEmpty ? nil : certs
    }

    /// Extract the CN value from a subject string like
    /// "OU=...,O=...,CN=node.fqdn".
    static func commonName(fromSubject subject: String?) -> String? {
        guard let subject else { return nil }
        for field in subject.components(separatedBy: ",") {
            let f = field.trimmingCharacters(in: .whitespaces)
            if f.uppercased().hasPrefix("CN=") { return String(f.dropFirst(3)) }
        }
        return nil
    }

    /// Soft check that the leaf certificate's common name matches the CN in
    /// the expected `host-subject`. Logged, not enforced, in v1 — CA
    /// anchoring is the hard trust boundary; strict DN matching is a TODO.
    private static func warnIfSubjectMismatch(_ trust: SecTrust, expected: String) {
        guard let cn = expected
            .components(separatedBy: ",")
            .first(where: { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("CN=") })?
            .trimmingCharacters(in: .whitespaces).dropFirst(3) else { return }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return }
        let summary = SecCertificateCopySubjectSummary(leaf) as String? ?? ""
        if summary != String(cn) {
            log.notice("SPICE TLS host-subject CN mismatch: cert=\(summary, privacy: .public) expected=\(String(cn), privacy: .public)")
        }
    }
}
