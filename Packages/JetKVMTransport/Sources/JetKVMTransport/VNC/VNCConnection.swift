import Foundation
import Network
import Security
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "vnc-conn")

/// Records whether TLS trust evaluation failed for lack of a trusted anchor
/// (self-signed), so `open()` can surface `.untrustedCertificate` for the
/// trust-override prompt. Written from the TLS verify block (a global queue),
/// read after connect — lock-guarded.
private final class TLSTrustState: @unchecked Sendable {
    private let lock = NSLock()
    private var _failed = false
    var failed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failed }
        set { lock.lock(); _failed = newValue; lock.unlock() }
    }
}

/// A byte-stream the RFB stream engine reads through. `VNCConnection` is the
/// production implementation (a real TCP socket); tests substitute an
/// in-memory channel. An `actor` so socket access and the read path are
/// isolated; callers drive it via `await`.
protocol VNCByteChannel: Actor {
    /// Receive exactly `n` bytes or throw. Cancellation-aware.
    func readExactly(_ n: Int) async throws -> Data
    func send(_ data: Data) async throws
    /// Total bytes read since open (handshake + framing + payloads), for
    /// bandwidth stats. Monotonic.
    var bytesReceived: Int { get }
}

/// One RFB session's plain-TCP connection. Performs the RFB 3.8 handshake
/// (version → security → optional VNC auth → ClientInit/ServerInit), then
/// carries raw bytes for the stream engine.
///
/// Modeled on the SPICE channel connection: `noDelay` TCP (RFB is
/// latency-sensitive in both directions), fail-fast connect (Network.framework
/// parks unreachable hosts in `.waiting`), and cancellation-aware reads so a
/// server that accepts the socket but never replies can't hang us forever.
actor VNCConnection: VNCByteChannel {
    private let host: String
    private let port: UInt16
    /// Encrypt via VeNCrypt (in-band TLS upgrade). When set, `open()` inserts
    /// the VeNCrypt framer below `NWProtocolTLS` and `handshake` runs the inner
    /// auth over TLS; the plaintext RFB prefix is handled entirely by the framer.
    private let useTLS: Bool
    private let allowSelfSigned: Bool
    /// Username for the VeNCrypt "Plain" inner auth (nil/empty → Plain isn't
    /// offered as a preference).
    private let username: String?

    private var connection: NWConnection?
    private(set) var bytesReceived: Int = 0

    /// The protocol minor version the server agreed to (7 or 8); affects
    /// SecurityResult framing. Fixed at 8 on the TLS path (the framer replies 3.8).
    private var negotiatedMinor = 8

    /// The VeNCrypt sub-negotiation result (TLS path only), read after connect.
    private var negotiation: VeNCryptNegotiation?

    /// Cap on a single `NWConnection.receive` so a multi-megabyte Raw rect is
    /// pulled in bounded chunks instead of one monster read.
    private static let readChunk = 256 * 1024

    init(host: String, port: UInt16, useTLS: Bool = false,
         allowSelfSigned: Bool = false, username: String? = nil) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.allowSelfSigned = allowSelfSigned
        self.username = username
    }

    // MARK: - Lifecycle

    /// `hasPassword` reflects whether a password is available so the VeNCrypt
    /// subtype preference is accurate (a passwordless server that offers a None
    /// subtype isn't forced through a password-requiring one). Plain subtypes
    /// are still offered whenever a username is present, so a Plain-only server
    /// (PiKVM) started without a password reaches `.awaitingPassword` and
    /// prompts rather than failing outright.
    func open(hasPassword: Bool = false) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw VNCConnectionError.connectionFailed("invalid port \(port)")
        }

        let params: NWParameters
        let trustState = TLSTrustState()
        var negotiation: VeNCryptNegotiation?
        if useTLS {
            // VeNCrypt: framer does the plaintext prefix, TLS wraps everything
            // after. Framer goes *below* TLS (appended = bottom of the stack).
            let neg = VeNCryptNegotiation(
                hasUsername: !(username ?? "").isEmpty, hasPassword: hasPassword)
            negotiation = neg
            self.negotiation = neg
            params = NWParameters(tls: makeTLSOptions(trustState: trustState), tcp: Self.makeTCPOptions())
            let framer = NWProtocolFramer.Options(definition: VNCVeNCryptFramer.definition)
            params.defaultProtocolStack.applicationProtocols.append(framer)
            // Only one negotiation may be pending in the framer's FIFO at a time.
            await VeNCryptGate.shared.acquire()
            VNCVeNCryptFramer.enqueue(neg)
        } else {
            params = NWParameters(tls: nil, tcp: Self.makeTCPOptions())
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection = conn

        func releaseGate() async {
            if let neg = negotiation {
                VNCVeNCryptFramer.discardIfPending(neg) // clean up if the framer never ran
                await VeNCryptGate.shared.release()
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    var resumed = false
                    let resumeOnce: (Result<Void, Error>) -> Void = { result in
                        if !resumed { resumed = true; cont.resume(with: result) }
                    }
                    let timeout = DispatchWorkItem { conn.cancel() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            timeout.cancel()
                            resumeOnce(.success(()))
                        case .waiting(let error):
                            timeout.cancel()
                            resumeOnce(.failure(VNCConnectionError.connectionFailed("\(error)")))
                        case .failed(let error):
                            timeout.cancel()
                            resumeOnce(.failure(VNCConnectionError.connectionFailed("\(error)")))
                        case .cancelled:
                            resumeOnce(.failure(VNCConnectionError.connectionFailed("connect timed out or closed")))
                        default:
                            break
                        }
                    }
                    conn.start(queue: DispatchQueue.global(qos: .userInitiated))
                }
            } onCancel: {
                conn.cancel()
            }
            await releaseGate()
        } catch {
            await releaseGate()
            // On the TLS path, a failed connect is often a cert-trust or
            // VeNCrypt-negotiation problem — surface those specifically.
            if trustState.failed {
                throw VNCConnectionError.untrustedCertificate("the server's TLS certificate is not trusted")
            }
            if let failure = negotiation?.failure {
                throw VNCConnectionError.handshakeFailed(failure)
            }
            throw error
        }
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - Handshake

    /// Run the RFB handshake and return the server's `ServerInit`. `password`
    /// may be nil; if the server requires VNC auth and no password is set, this
    /// throws `.authFailed("password required")` so the App layer can prompt.
    func handshake(password: String?, shared: Bool = true) async throws -> RFBProtocol.ServerInit {
        // TLS path: the framer already ran the plaintext version + security +
        // VeNCrypt sub-negotiation; we resume at the inner auth, over TLS.
        if let negotiation {
            return try await handshakeOverTLS(negotiation: negotiation, password: password, shared: shared)
        }

        // 1. Version exchange. "RFB xxx.yyy\n".
        let versionData = try await readExactly(RFBProtocol.versionByteCount)
        guard let version = String(data: versionData, encoding: .ascii),
              version.hasPrefix("RFB ") else {
            throw VNCConnectionError.unsupportedVersion("bad version string")
        }
        let parts = version.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]), major == 3, minor >= 7 else {
            throw VNCConnectionError.unsupportedVersion(version.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        negotiatedMinor = min(minor, 8)
        try await send(Data(String(format: "RFB 003.%03d\n", negotiatedMinor).utf8))

        // 2. Security types (3.7+ list form).
        let count = try await readExactly(1)[0]
        if count == 0 {
            let reason = try await readReasonString()
            throw VNCConnectionError.handshakeFailed(reason.isEmpty ? "server refused connection" : reason)
        }
        let offered = [UInt8](try await readExactly(Int(count)))
        let chosen: RFBProtocol.SecurityType
        if offered.contains(RFBProtocol.SecurityType.none.rawValue) {
            chosen = .none
        } else if offered.contains(RFBProtocol.SecurityType.vncAuth.rawValue) {
            chosen = .vncAuth
        } else {
            throw VNCConnectionError.handshakeFailed("no supported security type (offered \(offered))")
        }

        // 3. Authenticate.
        switch chosen {
        case .none:
            try await send(Data([RFBProtocol.SecurityType.none.rawValue]))
        case .vncAuth:
            guard let password, !password.isEmpty else {
                // Don't commit to VNC auth without a password; the App layer
                // prompts and reconnects.
                throw VNCConnectionError.authFailed("password required")
            }
            try await send(Data([RFBProtocol.SecurityType.vncAuth.rawValue]))
            let challenge = try await readExactly(16)
            try await send(VNCAuth.response(challenge: challenge, password: password))
        case .invalid:
            throw VNCConnectionError.handshakeFailed("invalid security type")
        case .veNCrypt:
            // Only reachable if selected above, which we never do on the
            // plaintext path (VeNCrypt runs through the TLS framer).
            throw VNCConnectionError.handshakeFailed("VeNCrypt requires the TLS transport")
        }

        // 4. SecurityResult. Always sent in 3.8; in 3.7 only after VNC auth.
        if negotiatedMinor >= 8 || chosen == .vncAuth {
            let result = try await readU32()
            if result != 0 {
                let reason = negotiatedMinor >= 8 ? try await readReasonString() : ""
                if chosen == .vncAuth {
                    throw VNCConnectionError.authFailed(reason.isEmpty ? "authentication failed" : reason)
                }
                throw VNCConnectionError.handshakeFailed(reason.isEmpty ? "security handshake failed" : reason)
            }
        }

        // 5. ClientInit → ServerInit.
        return try await clientAndServerInit(shared: shared)
    }

    /// VeNCrypt handshake resumed after the framer's plaintext prefix: inner
    /// auth (None/VNCAuth/Plain) over TLS, then SecurityResult and
    /// ClientInit/ServerInit.
    private func handshakeOverTLS(
        negotiation: VeNCryptNegotiation, password: String?, shared: Bool
    ) async throws -> RFBProtocol.ServerInit {
        if let failure = negotiation.failure {
            throw VNCConnectionError.handshakeFailed(failure)
        }
        guard let inner = negotiation.innerAuth else {
            throw VNCConnectionError.handshakeFailed("VeNCrypt negotiation did not complete")
        }
        negotiatedMinor = 8 // the framer replied 3.8

        switch inner {
        case .none:
            break
        case .vnc:
            guard let password, !password.isEmpty else {
                throw VNCConnectionError.authFailed("password required")
            }
            let challenge = try await readExactly(16)
            try await send(VNCAuth.response(challenge: challenge, password: password))
        case .plain:
            guard let username, !username.isEmpty else {
                throw VNCConnectionError.authFailed("username required")
            }
            guard let password, !password.isEmpty else {
                throw VNCConnectionError.authFailed("password required")
            }
            try await send(RFBProtocol.veNCryptPlainAuth(username: username, password: password))
        }

        // SecurityResult (always sent in 3.8).
        let result = try await readU32()
        if result != 0 {
            let reason = try await readReasonString()
            throw VNCConnectionError.authFailed(reason.isEmpty ? "authentication failed" : reason)
        }
        return try await clientAndServerInit(shared: shared)
    }

    /// ClientInit (shared flag) → ServerInit (size, pixel format, name).
    private func clientAndServerInit(shared: Bool) async throws -> RFBProtocol.ServerInit {
        try await send(Data([shared ? 1 : 0]))
        let head = try await readExactly(2 + 2 + RFBProtocol.PixelFormat.byteCount + 4)
        var r = VNCByteReader(head)
        let width = Int(try r.readU16())
        let height = Int(try r.readU16())
        // Bound the initial framebuffer like the DesktopSize path does — a
        // hostile ServerInit of 65535×65535 would otherwise request a ~17 GB
        // allocation.
        guard width <= 16_384, height <= 16_384 else {
            throw VNCConnectionError.protocolError("implausible framebuffer size \(width)x\(height)")
        }
        let pf = try RFBProtocol.PixelFormat.parse(&r)
        let nameLength = Int(try r.readU32())
        guard nameLength <= 4096 else {
            throw VNCConnectionError.protocolError("implausible desktop-name length \(nameLength)")
        }
        let nameData = nameLength > 0 ? try await readExactly(nameLength) : Data()
        let name = String(data: nameData, encoding: .utf8) ?? ""
        return RFBProtocol.ServerInit(width: width, height: height, pixelFormat: pf, name: name)
    }

    private func readU32() async throws -> UInt32 {
        var r = VNCByteReader(try await readExactly(4))
        return try r.readU32()
    }

    /// Read a u32-length-prefixed reason string (RFB failure messages).
    private func readReasonString() async throws -> String {
        let length = Int(try await readU32())
        guard length > 0, length <= 4096 else { return "" }
        let data = try await readExactly(length)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Byte channel

    func readExactly(_ n: Int) async throws -> Data {
        guard n > 0 else { return Data() }
        var buffer = Data()
        buffer.reserveCapacity(n)
        while buffer.count < n {
            let want = min(n - buffer.count, Self.readChunk)
            buffer.append(try await receiveExact(want))
        }
        bytesReceived += buffer.count
        return buffer
    }

    /// Receive exactly `want` bytes from the socket. Cancellation-aware: a
    /// cancelled enclosing task tears down the connection so a stalled read
    /// unblocks.
    private func receiveExact(_ want: Int) async throws -> Data {
        guard let conn = connection else { throw VNCConnectionError.connectionClosed }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                conn.receive(minimumIncompleteLength: want, maximumLength: want) { content, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: VNCConnectionError.connectionFailed("\(error)"))
                        return
                    }
                    if let content, content.count == want {
                        cont.resume(returning: content)
                    } else if isComplete {
                        cont.resume(throwing: VNCConnectionError.connectionClosed)
                    } else {
                        cont.resume(throwing: VNCConnectionError.protocolError(
                            "short read: got \(content?.count ?? 0)/\(want)"))
                    }
                }
            }
        } onCancel: {
            conn.cancel()
        }
    }

    func send(_ data: Data) async throws {
        guard let conn = connection else { throw VNCConnectionError.connectionClosed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: VNCConnectionError.connectionFailed("\(error)")) }
                else { cont.resume() }
            })
        }
    }

    // MARK: - Socket options

    /// TCP options with Nagle disabled. RFB input events and update requests
    /// have nothing queued behind them, so Nagle + the peer's delayed-ACK would
    /// stall them tens of ms. `noDelay` sends them immediately.
    private static func makeTCPOptions() -> NWProtocolTCP.Options {
        let o = NWProtocolTCP.Options()
        o.noDelay = true
        o.enableKeepalive = true
        return o
    }

    /// TLS options for the VeNCrypt upgrade. The verify block accepts a
    /// system-trusted chain outright; on failure it accepts only if the user
    /// opted into trusting this host's self-signed cert (`allowSelfSigned`),
    /// otherwise it records the failure so `open()` can surface the trust
    /// prompt. SNI is set to the host.
    private func makeTLSOptions(trustState: TLSTrustState) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(sec, host)
        let allow = allowSelfSigned
        sec_protocol_options_set_verify_block(
            sec,
            { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                var evalError: CFError?
                if SecTrustEvaluateWithError(trust, &evalError) {
                    complete(true)
                } else if allow {
                    complete(true) // user opted into trusting self-signed
                } else {
                    trustState.failed = true
                    complete(false)
                }
            },
            DispatchQueue.global())
        return tls
    }
}
