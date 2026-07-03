import Foundation
import KVMCore
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "pikvm-ws")

public enum PiKVMTransportError: Error, Sendable {
    case notConnected
    case alreadyConnected
    case transport(String)
    /// Signaling failed to produce a usable video stream (e.g. Janus
    /// `watch` kept failing).
    case signalingFailed(String)
}

/// WebSocket client for PiKVM's `/api/ws` — the input + state channel.
/// Outbound keyboard/mouse events are JSON text frames (see
/// `PiKVMEvent`); the keepalive is a *binary* `[0]` byte answered by a
/// `255` byte. Inbound `hid` state events are surfaced on `hidStates`
/// so the backend can pick absolute vs relative pointer mode.
///
/// Cookie auth rides the upgrade via the shared `HTTPCookieStorage`,
/// exactly as `SignalingClient` does for JetKVM.
public actor PiKVMEventClient {
    private let endpoint: DeviceEndpoint
    private let cookieStorage: HTTPCookieStorage?
    private let path: String

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var tlsDelegate: TLSDelegate?

    private var hidContinuation: AsyncStream<PiKVMEvent.HIDState>.Continuation?
    /// Inbound `hid` state events (absolute/relative mode, online).
    public private(set) var hidStates: AsyncStream<PiKVMEvent.HIDState>!

    /// Heartbeat cadence and tolerance, mirroring the web client.
    private static let pingInterval: Duration = .seconds(1)

    public init(
        endpoint: DeviceEndpoint,
        cookieStorage: HTTPCookieStorage?,
        path: String = "/api/ws"
    ) {
        self.endpoint = endpoint
        self.cookieStorage = cookieStorage
        self.path = path
    }

    public func connect() async throws {
        guard task == nil else { throw PiKVMTransportError.alreadyConnected }

        let config = URLSessionConfiguration.ephemeral
        if let cookieStorage { config.httpCookieStorage = cookieStorage }
        let delegate = TLSDelegate(allowSelfSignedCertificate: endpoint.allowSelfSignedCertificate)
        self.tlsDelegate = delegate
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = session

        self.hidStates = AsyncStream<PiKVMEvent.HIDState> { continuation in
            self.hidContinuation = continuation
        }

        let url = endpoint.webSocketURL(path: path)
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        log.info("WS opened to \(url.absoluteString, privacy: .public)")

        receiveTask = Task { [weak self] in await self?.receiveLoop(task: task) }
        heartbeatTask = Task { [weak self] in await self?.heartbeatLoop(task: task) }
    }

    /// Send one input event (UTF-8 JSON from `PiKVMEvent`) as a text frame.
    public func send(_ json: Data) async {
        guard let task else { return }
        let text = String(decoding: json, as: UTF8.self)
        do {
            try await task.send(.string(text))
        } catch {
            log.error("WS send failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func disconnect() async {
        receiveTask?.cancel(); receiveTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        hidContinuation?.finish(); hidContinuation = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Internal

    private func heartbeatLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pingInterval)
            if Task.isCancelled { return }
            do {
                try await task.send(.data(PiKVMEvent.pingFrame))
            } catch {
                log.error("WS heartbeat failed: \(String(describing: error), privacy: .public)")
                return
            }
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let frame: URLSessionWebSocketTask.Message
            do {
                frame = try await task.receive()
            } catch {
                // A cancelled task means we're tearing down on purpose
                // (window closed); the socket-closed throw is expected,
                // so don't log it as an error.
                if !Task.isCancelled {
                    log.error("WS receive failed: \(String(describing: error), privacy: .public)")
                }
                hidContinuation?.finish()
                return
            }
            switch frame {
            case .data(let data):
                // Binary heartbeat pong (`255`); ignore otherwise.
                if data.first == PiKVMEvent.pongByte { continue }
            case .string(let str):
                handleTextFrame(str)
            @unknown default:
                continue
            }
        }
    }

    private func handleTextFrame(_ str: String) {
        let data = Data(str.utf8)
        guard let type = PiKVMEvent.incomingType(data) else { return }
        if type == "hid", let hid = PiKVMEvent.decodeHIDState(data) {
            hidContinuation?.yield(hid)
        }
        // Other state events (atx, streamer, …) are ignored in v1.
    }
}
