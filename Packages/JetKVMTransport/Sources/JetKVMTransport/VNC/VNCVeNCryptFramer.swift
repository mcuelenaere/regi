import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "vnc-vencrypt")

/// Carries the VeNCrypt sub-negotiation across the connection boundary: the
/// framer reads its inputs (which subtypes we can accept) and writes back the
/// subtype it chose (or a failure). `VNCConnection` reads the result once the
/// connection is ready to run the matching inner auth over TLS.
final class VeNCryptNegotiation: @unchecked Sendable {
    let hasUsername: Bool
    let hasPassword: Bool

    private let lock = NSLock()
    private var _chosenSubtype: UInt32?
    private var _failure: String?

    init(hasUsername: Bool, hasPassword: Bool) {
        self.hasUsername = hasUsername
        self.hasPassword = hasPassword
    }

    var chosenSubtype: UInt32? {
        get { lock.lock(); defer { lock.unlock() }; return _chosenSubtype }
        set { lock.lock(); _chosenSubtype = newValue; lock.unlock() }
    }
    var failure: String? {
        get { lock.lock(); defer { lock.unlock() }; return _failure }
        set { lock.lock(); _failure = newValue; lock.unlock() }
    }
    var innerAuth: RFBProtocol.VeNCrypt.InnerAuth? {
        chosenSubtype.flatMap { RFBProtocol.VeNCrypt.innerAuth(for: $0) }
    }
}

/// Serializes VeNCrypt connects so only one negotiation is in the framer's
/// static FIFO at a time — the FIFO can only associate a negotiation with a
/// framer by order, and framer `start()` callbacks for independent connections
/// fire in an unspecified order. Held from just before `enqueue` until the
/// connection is ready (or failed).
actor VeNCryptGate {
    static let shared = VeNCryptGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}

/// `NWProtocolFramer` that performs the plaintext RFB + VeNCrypt sub-handshake,
/// then becomes a transparent byte pass-through. Placed *below* `NWProtocolTLS`
/// so the flow is: TCP → [RFB version + security-type 19 + VeNCrypt subtype
/// negotiation] → TLS → RFB inner auth + session. Mirrors the sibling
/// `SpiceProxyTunnel` (plaintext prefix under TLS), but with VeNCrypt's
/// multi-step negotiation state machine.
///
/// Once the framer reads the server's TLS-ack it `markReady()`s; the TLS layer
/// above then sends its ClientHello (held until now) and the socket is
/// encrypted for everything that follows.
final class VNCVeNCryptFramer: NWProtocolFramerImplementation {
    static let label = "VNCVeNCrypt"
    static let definition = NWProtocolFramer.Definition(implementation: VNCVeNCryptFramer.self)

    private static let lock = NSLock()
    private static var pending: [VeNCryptNegotiation] = []
    /// Enqueue the negotiation for the next connection's framer. The caller
    /// holds `VeNCryptGate` across the connect so exactly one negotiation is
    /// pending at a time (the FIFO can't associate by anything but order).
    static func enqueue(_ negotiation: VeNCryptNegotiation) {
        lock.lock(); pending.append(negotiation); lock.unlock()
    }
    private static func dequeue() -> VeNCryptNegotiation? {
        lock.lock(); defer { lock.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst()
    }
    /// Remove a negotiation still waiting in the queue — called by the connect
    /// path on exit so a connection that failed before its framer's `start()`
    /// ran can't leak a stale entry the next connection would dequeue. No-op if
    /// it was already dequeued.
    static func discardIfPending(_ negotiation: VeNCryptNegotiation) {
        lock.lock(); defer { lock.unlock() }
        if let idx = pending.firstIndex(where: { $0 === negotiation }) {
            pending.remove(at: idx)
        }
    }

    private enum State {
        case version, security, vencryptVersion, vencryptAck, subtypes, tlsAck, established
    }
    private var state: State = .version
    private var negotiation: VeNCryptNegotiation?

    init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        negotiation = Self.dequeue()
        // The server speaks first (ProtocolVersion); mark ready only once the
        // whole plaintext prefix is done (in handleInput).
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        if state == .established { return passThrough(framer) }

        // Drive the state machine; each step consumes its bytes atomically
        // (nothing is consumed until a whole step is buffered).
        stepping: while true {
            switch state {
            case .version:
                guard tryRead(framer, 12) != nil else { break stepping }
                framer.writeOutput(data: Data(RFBProtocol.versionString.utf8))
                state = .security

            case .security:
                guard let (count, body) = tryReadCounted(framer, elementSize: 1) else { break stepping }
                guard count > 0 else { fail("server refused the connection"); return 0 }
                guard body.contains(RFBProtocol.SecurityType.veNCrypt.rawValue) else {
                    fail("server does not offer VeNCrypt/TLS")
                    return 0
                }
                framer.writeOutput(data: Data([RFBProtocol.SecurityType.veNCrypt.rawValue]))
                state = .vencryptVersion

            case .vencryptVersion:
                guard tryRead(framer, 2) != nil else { break stepping }
                framer.writeOutput(data: Data([RFBProtocol.VeNCrypt.version.major,
                                               RFBProtocol.VeNCrypt.version.minor]))
                state = .vencryptAck

            case .vencryptAck:
                guard let ack = tryRead(framer, 1) else { break stepping }
                guard ack[0] == 0 else { fail("server rejected the VeNCrypt version"); return 0 }
                state = .subtypes

            case .subtypes:
                guard let (count, body) = tryReadCounted(framer, elementSize: 4) else { break stepping }
                guard count > 0 else { fail("server offered no VeNCrypt subtypes"); return 0 }
                var offered: [UInt32] = []
                var i = 0
                while i + 4 <= body.count {
                    let b0 = UInt32(body[i]) << 24
                    let b1 = UInt32(body[i + 1]) << 16
                    let b2 = UInt32(body[i + 2]) << 8
                    let b3 = UInt32(body[i + 3])
                    offered.append(b0 | b1 | b2 | b3)
                    i += 4
                }
                let prefs = RFBProtocol.VeNCrypt.preferredSubtypes(
                    hasUsername: negotiation?.hasUsername ?? false,
                    hasPassword: negotiation?.hasPassword ?? false)
                guard let chosen = prefs.first(where: { offered.contains($0) }) else {
                    fail("no acceptable TLS-encrypted VeNCrypt subtype (offered \(offered))")
                    return 0
                }
                negotiation?.chosenSubtype = chosen
                var w = VNCByteWriter(); w.writeU32(chosen)
                framer.writeOutput(data: w.data)
                state = .tlsAck

            case .tlsAck:
                guard let ack = tryRead(framer, 1) else { break stepping }
                guard ack[0] == 1 else { fail("server declined TLS (ack \(ack[0]))"); return 0 }
                state = .established
                log.debug("VeNCrypt negotiated; upgrading to TLS")
                framer.markReady()
                return passThrough(framer)

            case .established:
                return passThrough(framer)
            }
        }
        return 0
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message,
                      messageLength: Int, isComplete: Bool) {
        // Transparent pass-through of upper-layer (TLS) output.
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    // MARK: - Helpers

    private func fail(_ reason: String) {
        log.error("VeNCrypt handshake failed: \(reason, privacy: .public)")
        negotiation?.failure = reason
        // No markReady → the connect-level timeout surfaces this as a failure.
    }

    /// Consume exactly `n` bytes if that many are buffered, else consume
    /// nothing and return nil (wait for more).
    private func tryRead(_ framer: NWProtocolFramer.Instance, _ n: Int) -> [UInt8]? {
        var result: [UInt8]?
        _ = framer.parseInput(minimumIncompleteLength: n, maximumLength: n) { buffer, _ in
            guard let buffer, buffer.count >= n, let base = buffer.baseAddress else { return 0 }
            result = Array(UnsafeRawBufferPointer(start: base, count: n))
            return n
        }
        return result
    }

    /// Read a 1-byte count followed by `count * elementSize` body bytes, all or
    /// nothing. Returns (count, body-bytes).
    private func tryReadCounted(_ framer: NWProtocolFramer.Instance, elementSize: Int) -> (Int, [UInt8])? {
        var result: (Int, [UInt8])?
        _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 65535) { buffer, _ in
            guard let buffer, buffer.count >= 1, let base = buffer.baseAddress else { return 0 }
            let count = Int(base.load(fromByteOffset: 0, as: UInt8.self))
            let need = 1 + count * elementSize
            guard buffer.count >= need else { return 0 }
            let body = count > 0
                ? Array(UnsafeRawBufferPointer(start: base + 1, count: count * elementSize))
                : []
            result = (count, body)
            return need
        }
        return result
    }

    private func passThrough(_ framer: NWProtocolFramer.Instance) -> Int {
        let message = NWProtocolFramer.Message(definition: Self.definition)
        _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 65535) { buffer, isComplete in
            guard let buffer, buffer.count > 0, let base = buffer.baseAddress else { return 0 }
            let data = Data(bytes: base, count: buffer.count)
            _ = framer.deliverInput(data: data, message: message, isComplete: isComplete)
            return buffer.count
        }
        return 0
    }
}
