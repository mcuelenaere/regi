import Foundation
import Network
import XCTest
@testable import JetKVMTransport

/// In-memory `VNCByteChannel` for driving the stream engine with scripted
/// server bytes and capturing what the client sends. No socket.
actor ScriptedByteChannel: VNCByteChannel {
    private var inbound: Data
    private var offset = 0
    private(set) var sent = Data()
    private(set) var bytesReceived = 0
    /// Set when inbound is exhausted, so a blocked `readExactly` reports EOF
    /// instead of hanging.
    private var closed = false

    init(_ data: Data = Data()) { inbound = data }

    func append(_ d: Data) { inbound.append(d) }
    func closeInbound() { closed = true }

    func readExactly(_ n: Int) async throws -> Data {
        guard n > 0 else { return Data() }
        guard offset + n <= inbound.count else {
            throw VNCConnectionError.connectionClosed
        }
        let start = inbound.startIndex + offset
        let slice = inbound.subdata(in: start..<(start + n))
        offset += n
        bytesReceived += n
        return slice
    }

    func send(_ data: Data) async throws { sent.append(data) }
}

/// A loopback RFB server for handshake tests. Listens on a random localhost
/// port, drives the server side of the RFB 3.x handshake, and reports the
/// outcome. Modeled on the SPICE test harness.
final class FakeRFBServer: @unchecked Sendable {
    struct Config {
        var version = "RFB 003.008\n"
        /// Security types to offer. Empty → send count 0 + `refusalReason`.
        var securityTypes: [UInt8] = [1] // none
        var refusalReason = "no way"
        /// For VNC auth: the password the server accepts. The 16-byte
        /// challenge is fixed for determinism.
        var expectedPassword = "secret"
        var challenge = Data((0..<16).map { UInt8($0) })
        var width = 640
        var height = 480
        var name = "fake"
    }

    struct Outcome {
        var clientVersion: String?
        var chosenSecurity: UInt8?
        var authResponse: Data?
        var authAccepted: Bool?
        var clientShared: UInt8?
        var error: String?
    }

    private let listener: NWListener
    private let config: Config
    private let lock = NSLock()
    private var outcome = Outcome()
    private var waiter: CheckedContinuation<Outcome, Never>?
    private var finished = false

    init(config: Config = Config()) throws {
        self.config = config
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// Start listening; returns the bound localhost port.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global())
            Task { [weak self] in await self?.handle(conn) }
        }
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let p = self?.listener.port?.rawValue { cont.resume(returning: p) }
                case .failed(let e):
                    cont.resume(throwing: e)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() { listener.cancel() }

    /// Await the handshake outcome the server observed.
    func result() async -> Outcome {
        await withCheckedContinuation { cont in
            lock.lock()
            if finished { lock.unlock(); cont.resume(returning: outcome) }
            else { waiter = cont; lock.unlock() }
        }
    }

    private func finish() {
        lock.lock()
        finished = true
        let w = waiter
        waiter = nil
        let o = outcome
        lock.unlock()
        w?.resume(returning: o)
    }

    private func record(_ mutate: (inout Outcome) -> Void) {
        lock.lock(); mutate(&outcome); lock.unlock()
    }

    private func handle(_ conn: NWConnection) async {
        do {
            try await sendRaw(conn, Data(config.version.utf8))
            let clientVer = try await recv(conn, 12)
            record { $0.clientVersion = String(data: clientVer, encoding: .ascii) }

            // Security list.
            if config.securityTypes.isEmpty {
                var w = VNCByteWriter()
                w.writeU8(0)
                let reason = Array(config.refusalReason.utf8)
                w.writeU32(UInt32(reason.count))
                w.writeBytes(reason)
                try await sendRaw(conn, w.data)
                finish()
                return
            }
            var secList = Data([UInt8(config.securityTypes.count)])
            secList.append(contentsOf: config.securityTypes)
            try await sendRaw(conn, secList)

            let chosen = try await recv(conn, 1)[0]
            record { $0.chosenSecurity = chosen }

            var authOK = true
            if chosen == 2 {
                try await sendRaw(conn, config.challenge)
                let response = try await recv(conn, 16)
                let expected = VNCAuth.response(challenge: config.challenge, password: config.expectedPassword)
                authOK = (response == expected)
                record { $0.authResponse = response; $0.authAccepted = authOK }
            }

            // SecurityResult (always in 3.8; here we send it unconditionally
            // since our tests pin 3.8 unless overriding version).
            var res = VNCByteWriter()
            res.writeU32(authOK ? 0 : 1)
            if !authOK {
                let reason = Array("auth failed".utf8)
                res.writeU32(UInt32(reason.count))
                res.writeBytes(reason)
            }
            try await sendRaw(conn, res.data)
            if !authOK { finish(); return }

            let shared = try await recv(conn, 1)[0]
            record { $0.clientShared = shared }

            // ServerInit.
            var si = VNCByteWriter()
            si.writeU16(UInt16(config.width))
            si.writeU16(UInt16(config.height))
            RFBProtocol.PixelFormat.bgra32.encode(into: &si)
            let name = Array(config.name.utf8)
            si.writeU32(UInt32(name.count))
            si.writeBytes(name)
            try await sendRaw(conn, si.data)
            finish()
        } catch {
            record { $0.error = "\(error)" }
            finish()
        }
    }

    private func recv(_ conn: NWConnection, _ n: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { content, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                if let content, content.count == n { cont.resume(returning: content) }
                else { cont.resume(throwing: VNCConnectionError.connectionClosed) }
            }
        }
    }

    private func sendRaw(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }
}
