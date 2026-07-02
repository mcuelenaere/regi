import Foundation
import Network
import Security
@testable import JetKVMTransport

/// Shared crypto helpers for SPICE tests.
enum SpiceTestCrypto {
    static func makeRSAKeyPair(bits: Int) throws -> (private: SecKey, public: SecKey) {
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: NSNumber(value: bits),
        ]
        var err: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
            throw NSError(domain: "SpiceTestCrypto", code: 1)
        }
        guard let pub = SecKeyCopyPublicKey(priv) else {
            throw NSError(domain: "SpiceTestCrypto", code: 2)
        }
        return (priv, pub)
    }

    /// Wrap PKCS#1 RSAPublicKey DER into an X.509 SubjectPublicKeyInfo, as a
    /// SPICE server would present it.
    static func wrapPKCS1AsSPKI(_ pkcs1: [UInt8]) -> [UInt8] {
        let algId: [UInt8] = [
            0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86,
            0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00,
        ]
        var bitStringContent: [UInt8] = [0x00]
        bitStringContent.append(contentsOf: pkcs1)
        var bitString: [UInt8] = [0x03]
        bitString.append(contentsOf: derLength(bitStringContent.count))
        bitString.append(contentsOf: bitStringContent)

        var body = algId
        body.append(contentsOf: bitString)
        var spki: [UInt8] = [0x30]
        spki.append(contentsOf: derLength(body.count))
        spki.append(contentsOf: body)
        return spki
    }

    static func spkiPublicKey(bits: Int) throws -> (private: SecKey, spki: [UInt8]) {
        let (priv, pub) = try makeRSAKeyPair(bits: bits)
        var err: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(pub, &err) as Data? else {
            throw NSError(domain: "SpiceTestCrypto", code: 3)
        }
        return (priv, wrapPKCS1AsSPKI([UInt8](pkcs1)))
    }

    private static func derLength(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        if n <= 0xFF { return [0x81, UInt8(n)] }
        return [0x82, UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    }
}

/// In-process fake SPICE server for exercising `SpiceChannelConnection` over
/// a real loopback socket — the transport + link handshake + ticket auth,
/// without needing a SPICE-capable QEMU (which Homebrew doesn't ship).
///
/// Serves exactly one connection: replies to the link message with a real
/// RSA public key, decrypts the client's ticket, and returns success.
final class FakeSpiceServer {
    private let listener: NWListener
    private let privateKey: SecKey
    let spki: [UInt8]
    /// When true, the server first consumes an HTTP CONNECT request and
    /// replies 200 (acting as a plaintext CONNECT proxy) before the SPICE
    /// handshake — used to exercise the client's proxy-tunnel framer.
    private let expectConnect: Bool
    /// The CONNECT target the client requested (when `expectConnect`).
    private(set) var capturedTarget: String?

    private let lock = DispatchQueue(label: "fake-spice-server")
    private var captured: Result<String, Error>?
    private var waiter: CheckedContinuation<String, Error>?

    init(expectConnect: Bool = false) throws {
        (self.privateKey, self.spki) = try SpiceTestCrypto.spkiPublicKey(bits: 1024)
        self.expectConnect = expectConnect
        self.listener = try NWListener(using: .tcp, on: .any)
    }

    /// Start listening; returns the bound loopback port.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global())
            Task { [weak self] in await self?.handle(conn) }
        }
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let p = self.listener.port?.rawValue { cont.resume(returning: p) }
                    else { cont.resume(throwing: NSError(domain: "FakeSpiceServer", code: 10)) }
                case .failed(let e):
                    cont.resume(throwing: e)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    /// Await the password the client authenticated with (or an error).
    func capturedPassword() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            lock.async {
                if let r = self.captured { self.captured = nil; cont.resume(with: r) }
                else { self.waiter = cont }
            }
        }
    }

    func stop() { listener.cancel() }

    // MARK: - Server-side handshake

    private func handle(_ conn: NWConnection) async {
        do {
            // 0. If acting as a CONNECT proxy, consume the request + reply 200.
            if expectConnect {
                let request = try await recvUntilHeaderEnd(conn)
                if let firstLine = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first {
                    let parts = firstLine.split(separator: " ")
                    if parts.count >= 2 { capturedTarget = String(parts[1]) }
                }
                try await sendRaw(conn, Data("HTTP/1.0 200 Connection established\r\n\r\n".utf8))
            }

            // 1. Read client link header + body.
            let header = try SpiceLinkHeader.parse(try await recv(conn, 16))
            _ = try await recv(conn, Int(header.size))   // client mess (ignored)

            // 2. Send our reply.
            try await sendRaw(conn, buildReply())

            // 3. Read auth mechanism (u32) + 128-byte ticket.
            _ = try await recv(conn, 4)
            let ticket = try await recv(conn, SpiceProtocol.ticketEncryptedBytes)

            // 4. Decrypt and capture the password.
            var err: Unmanaged<CFError>?
            guard let plain = SecKeyCreateDecryptedData(
                privateKey, .rsaEncryptionOAEPSHA1, ticket as CFData, &err) as Data? else {
                throw NSError(domain: "FakeSpiceServer", code: 20)
            }
            var bytes = [UInt8](plain)
            if bytes.last == 0 { bytes.removeLast() }
            let password = String(decoding: bytes, as: UTF8.self)

            // 5. Send success result.
            var w = SpiceByteWriter(); w.writeU32(SpiceProtocol.LinkErr.ok.rawValue)
            try await sendRaw(conn, w.data)

            complete(.success(password))
        } catch {
            complete(.failure(error))
        }
    }

    private func buildReply() -> Data {
        var body = SpiceByteWriter()
        body.writeU32(SpiceProtocol.LinkErr.ok.rawValue)
        body.writeBytes(spki)
        let common = SpiceCaps(bits: [
            SpiceProtocol.CommonCap.protocolAuthSelection.rawValue,
            SpiceProtocol.CommonCap.miniHeader.rawValue,
        ])
        body.writeU32(UInt32(common.wordCount))     // num_common_caps
        body.writeU32(0)                            // num_channel_caps
        body.writeU32(UInt32(4 + spki.count + 4 + 4 + 4))  // caps_offset = 178
        for word in common.words { body.writeU32(word) }

        var out = SpiceByteWriter()
        out.writeBytes(SpiceLinkHeader(major: 2, minor: 2, size: UInt32(body.count)).encode())
        out.writeBytes(body.data)
        return out.data
    }

    private func complete(_ r: Result<String, Error>) {
        lock.async {
            if let w = self.waiter { self.waiter = nil; w.resume(with: r) }
            else { self.captured = r }
        }
    }

    // MARK: - Socket helpers

    private func sendRaw(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func recv(_ conn: NWConnection, _ n: Int) async throws -> Data {
        guard n > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { content, _, isComplete, error in
                if let error { cont.resume(throwing: error) }
                else if let content, content.count == n { cont.resume(returning: content) }
                else { cont.resume(throwing: NSError(domain: "FakeSpiceServer", code: 30)) }
            }
        }
    }

    /// Read bytes until the "\r\n\r\n" header terminator; returns the header
    /// as a string.
    private func recvUntilHeaderEnd(_ conn: NWConnection) async throws -> String {
        var buffer = Data()
        while buffer.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) == nil {
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { content, _, isComplete, error in
                    if let error { cont.resume(throwing: error) }
                    else if let content, !content.isEmpty { cont.resume(returning: content) }
                    else { cont.resume(throwing: NSError(domain: "FakeSpiceServer", code: 31)) }
                }
            }
            buffer.append(chunk)
            if buffer.count > 8192 { break }
        }
        return String(decoding: buffer, as: UTF8.self)
    }
}
