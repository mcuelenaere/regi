import Foundation
import KVMCore
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "janus")

/// Janus WebSocket signaling for PiKVM video (`/janus/ws`, subprotocol
/// `janus-protocol`). Drives the µStreamer streaming plugin:
///
///   create → attach(janus.plugin.ustreamer) → watch → (server JSEP
///   offer) → caller answers → start(+answer) → trickle ICE → keepalive
///
/// The server creates the offer and we answer — the reverse of JetKVM.
/// `watch` is retried because µStreamer's stream may not be live yet on
/// the first attempt (documented behaviour).
public actor JanusSignalingClient {
    private let endpoint: DeviceEndpoint
    private let cookieStorage: HTTPCookieStorage?
    private let path: String

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var tlsDelegate: TLSDelegate?

    private var sessionId: UInt64?
    private var handleId: UInt64?

    private var txCounter: UInt64 = 0
    private var pending: [String: CheckedContinuation<JanusIncoming, Error>] = [:]
    private var pendingOffer: CheckedContinuation<String, Error>?

    private var candidateContinuation: AsyncStream<JanusCandidate>.Continuation?
    /// ICE candidates the server trickles to us (forwarded to the peer
    /// connection). Many streaming setups put all candidates in the
    /// offer SDP and never trickle, so this may stay empty.
    public private(set) var remoteCandidates: AsyncStream<JanusCandidate>!

    private static let keepaliveInterval: Duration = .seconds(25)
    private static let watchTimeout: Duration = .seconds(8)

    public init(
        endpoint: DeviceEndpoint,
        cookieStorage: HTTPCookieStorage?,
        path: String = "/janus/ws"
    ) {
        self.endpoint = endpoint
        self.cookieStorage = cookieStorage
        self.path = path
    }

    // MARK: - Lifecycle

    /// Open the socket, create a Janus session, and attach the µStreamer
    /// plugin. After this returns, call `watch()`.
    public func connect() async throws {
        guard task == nil else { throw PiKVMTransportError.alreadyConnected }

        let config = URLSessionConfiguration.ephemeral
        if let cookieStorage { config.httpCookieStorage = cookieStorage }
        let delegate = TLSDelegate(allowSelfSignedCertificate: endpoint.allowSelfSignedCertificate)
        self.tlsDelegate = delegate
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = session

        self.remoteCandidates = AsyncStream<JanusCandidate> { continuation in
            self.candidateContinuation = continuation
        }

        let url = endpoint.webSocketURL(path: path)
        let task = session.webSocketTask(with: url, protocols: ["janus-protocol"])
        self.task = task
        task.resume()
        log.info("Janus WS opened to \(url.absoluteString, privacy: .public)")

        receiveTask = Task { [weak self] in await self?.receiveLoop(task: task) }

        // create session
        let createResp = try await request(JanusMessage.create(transaction: nextTransaction()))
        guard let sid = createResp.data?.id else {
            throw PiKVMTransportError.signalingFailed("create returned no session id")
        }
        self.sessionId = sid

        keepaliveTask = Task { [weak self] in await self?.keepaliveLoop() }

        // attach plugin
        let attachResp = try await request(JanusMessage.attach(sessionId: sid, transaction: nextTransaction()))
        guard let hid = attachResp.data?.id else {
            throw PiKVMTransportError.signalingFailed("attach returned no handle id")
        }
        self.handleId = hid
        log.info("Janus session=\(sid, privacy: .public) handle=\(hid, privacy: .public)")
    }

    /// Send `watch` and await the server's JSEP offer, retrying because
    /// the µStreamer H.264 stream may not be live on the first attempt.
    /// Returns the raw offer SDP.
    public func watch(maxAttempts: Int = 5) async throws -> String {
        for attempt in 1...maxAttempts {
            do {
                return try await watchOnce()
            } catch {
                log.notice("watch attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(600))
                }
            }
        }
        throw PiKVMTransportError.signalingFailed("watch failed after \(maxAttempts) attempts")
    }

    private func watchOnce() async throws -> String {
        guard let sid = sessionId, let hid = handleId else { throw PiKVMTransportError.notConnected }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.pendingOffer = cont
            Task {
                do {
                    try await self.rawSend(JanusMessage.watch(sessionId: sid, handleId: hid, transaction: self.nextTransaction()))
                    // Timeout guard: if no offer arrives, fail so we retry.
                    Task {
                        try? await Task.sleep(for: Self.watchTimeout)
                        await self.failOfferIfPending(PiKVMTransportError.signalingFailed("watch timed out"))
                    }
                } catch {
                    self.failOfferIfPending(error)
                }
            }
        }
    }

    /// Answer the offer: `start` + the JSEP answer.
    public func sendAnswer(_ sdp: String) async throws {
        guard let sid = sessionId, let hid = handleId else { throw PiKVMTransportError.notConnected }
        try await rawSend(JanusMessage.startAnswer(sessionId: sid, handleId: hid, transaction: nextTransaction(), answerSDP: sdp))
    }

    public func sendTrickle(_ candidate: JanusCandidate) async {
        guard let sid = sessionId, let hid = handleId else { return }
        try? await rawSend(JanusMessage.trickle(sessionId: sid, handleId: hid, transaction: nextTransaction(), candidate: candidate))
    }

    public func sendTrickleCompleted() async {
        await sendTrickle(.completedSentinel)
    }

    public func disconnect() async {
        receiveTask?.cancel(); receiveTask = nil
        keepaliveTask?.cancel(); keepaliveTask = nil
        // Fail any in-flight waiters so callers don't hang.
        for (_, cont) in pending { cont.resume(throwing: PiKVMTransportError.notConnected) }
        pending.removeAll()
        failOfferIfPending(PiKVMTransportError.notConnected)
        candidateContinuation?.finish(); candidateContinuation = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        sessionId = nil
        handleId = nil
    }

    // MARK: - Internal

    private func nextTransaction() -> String {
        txCounter += 1
        return "tx-\(txCounter)"
    }

    /// Send a request that expects a `success`/`error` reply keyed by
    /// transaction (create, attach).
    private func request(_ data: Data) async throws -> JanusIncoming {
        let tx = try transactionOf(data)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JanusIncoming, Error>) in
            self.pending[tx] = cont
            Task {
                do { try await self.rawSend(data) }
                catch {
                    self.pending[tx] = nil
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// The transaction id embedded in an already-encoded outbound frame.
    private func transactionOf(_ data: Data) throws -> String {
        struct TX: Decodable { let transaction: String }
        return try JSONDecoder().decode(TX.self, from: data).transaction
    }

    private func rawSend(_ data: Data) async throws {
        guard let task else { throw PiKVMTransportError.notConnected }
        do {
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            throw PiKVMTransportError.transport(String(describing: error))
        }
    }

    private func failOfferIfPending(_ error: Error) {
        guard let cont = pendingOffer else { return }
        pendingOffer = nil
        cont.resume(throwing: error)
    }

    private func fulfillOffer(_ sdp: String) {
        guard let cont = pendingOffer else { return }
        pendingOffer = nil
        cont.resume(returning: sdp)
    }

    private func keepaliveLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.keepaliveInterval)
            if Task.isCancelled { return }
            guard let sid = sessionId else { return }
            try? await rawSend(JanusMessage.keepalive(sessionId: sid, transaction: nextTransaction()))
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let frame: URLSessionWebSocketTask.Message
            do {
                frame = try await task.receive()
            } catch {
                // Cancelled task → intentional teardown; the socket-closed
                // throw is expected, so don't log it as an error.
                if !Task.isCancelled {
                    log.error("Janus receive failed: \(String(describing: error), privacy: .public)")
                }
                failOfferIfPending(PiKVMTransportError.transport(String(describing: error)))
                return
            }
            guard case .string(let str) = frame else { continue }
            let data = Data(str.utf8)
            guard let msg = try? JanusIncoming.decode(data) else {
                log.error("Janus undecodable frame: \(str, privacy: .public)")
                continue
            }
            dispatch(msg)
        }
    }

    private func dispatch(_ msg: JanusIncoming) {
        switch msg.janus {
        case "success":
            if let tx = msg.transaction, let cont = pending.removeValue(forKey: tx) {
                cont.resume(returning: msg)
            }
        case "error":
            if let tx = msg.transaction, let cont = pending.removeValue(forKey: tx) {
                cont.resume(throwing: PiKVMTransportError.signalingFailed(msg.error?.reason ?? "janus error"))
            } else {
                // An error tied to the in-flight watch (e.g. stream not
                // ready) — fail the offer so watch() retries.
                failOfferIfPending(PiKVMTransportError.signalingFailed(msg.error?.reason ?? "janus error"))
            }
        case "event":
            // A plugin error (e.g. watch before stream is live) should
            // trigger a retry; otherwise look for the JSEP offer.
            if let pluginError = msg.plugindata?.data?.error {
                failOfferIfPending(PiKVMTransportError.signalingFailed(pluginError))
            } else if let jsep = msg.jsep, jsep.type == "offer" {
                fulfillOffer(jsep.sdp)
            }
        case "trickle":
            // Server-side ICE candidate (rare for streaming).
            if let cand = candidateFromTrickle(msg) {
                candidateContinuation?.yield(cand)
            }
        case "webrtcup":
            log.info("Janus webrtcup")
        case "hangup", "detached":
            log.notice("Janus \(msg.janus, privacy: .public)")
            failOfferIfPending(PiKVMTransportError.signalingFailed(msg.janus))
        case "timeout":
            log.error("Janus session timeout")
            failOfferIfPending(PiKVMTransportError.signalingFailed("session timeout"))
        default:
            // ack, keepalive, media, slowlink, … — nothing to do.
            break
        }
    }

    /// A real (non-sentinel) candidate from an inbound `trickle` frame,
    /// or nil for the end-of-candidates marker.
    private func candidateFromTrickle(_ msg: JanusIncoming) -> JanusCandidate? {
        guard let c = msg.candidate, c.completed != true, c.candidate != nil else { return nil }
        return c
    }
}
