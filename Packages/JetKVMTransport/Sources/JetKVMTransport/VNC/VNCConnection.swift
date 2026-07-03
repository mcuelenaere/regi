import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "vnc-conn")

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
    private var connection: NWConnection?
    private(set) var bytesReceived: Int = 0

    /// The protocol minor version the server agreed to (7 or 8); affects
    /// SecurityResult framing.
    private var negotiatedMinor = 8

    /// Cap on a single `NWConnection.receive` so a multi-megabyte Raw rect is
    /// pulled in bounded chunks instead of one monster read.
    private static let readChunk = 256 * 1024

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    // MARK: - Lifecycle

    func open() async throws {
        let params = NWParameters(tls: nil, tcp: Self.makeTCPOptions())
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw VNCConnectionError.connectionFailed("invalid port \(port)")
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection = conn

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
}
