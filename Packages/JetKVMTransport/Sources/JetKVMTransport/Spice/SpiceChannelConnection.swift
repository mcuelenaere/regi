import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "spice-conn")

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

    private var connection: NWConnection?
    private var sendSerial: UInt64 = 1

    /// Negotiated after the handshake.
    private(set) var useMiniHeader = false
    private(set) var connectionID: UInt32 = 0

    init(host: String, port: UInt16, useTLS: Bool, allowSelfSigned: Bool,
         channelType: SpiceProtocol.ChannelType, channelID: UInt8,
         connectionID: UInt32 = 0) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.allowSelfSigned = allowSelfSigned
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

    private func openSocket() async throws {
        let params: NWParameters
        if useTLS {
            let tls = NWProtocolTLS.Options()
            if allowSelfSigned {
                sec_protocol_options_set_verify_block(
                    tls.securityProtocolOptions,
                    { _, _, complete in complete(true) },   // accept self-signed
                    DispatchQueue.global()
                )
            }
            params = NWParameters(tls: tls)
        } else {
            params = NWParameters.tcp
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SpiceConnectionError.connectionFailed("invalid port \(port)")
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            let resumeOnce: (Result<Void, Error>) -> Void = { result in
                if !resumed { resumed = true; cont.resume(with: result) }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .waiting(let error):
                    // Network.framework parks unreachable/refused connections
                    // in `.waiting` and retries indefinitely. For a console
                    // connecting to a specific host we want to fail fast.
                    resumeOnce(.failure(SpiceConnectionError.connectionFailed("\(error)")))
                case .failed(let error):
                    resumeOnce(.failure(SpiceConnectionError.connectionFailed("\(error)")))
                case .cancelled:
                    resumeOnce(.failure(SpiceConnectionError.connectionClosed))
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
}
