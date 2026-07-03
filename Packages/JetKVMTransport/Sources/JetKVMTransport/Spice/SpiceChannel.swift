import Foundation
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "spice-channel")

/// Base per-channel message pump over a linked `SpiceChannelConnection`.
///
/// Runs a background read loop that handles the common BaseChannel
/// flow-control automatically — replies to SET_ACK with ACK_SYNC and sends
/// a periodic ACK every `window` messages (without this the server stops
/// sending after one window), and answers PING with PONG — then forwards
/// channel-specific messages to `handle(type:payload:)`.
///
/// Subclasses set their callbacks before calling `start()`. Callbacks fire on
/// the read-loop task; the backend marshals to the main actor.
class SpiceChannel {
    let connection: SpiceChannelConnection

    private var runTask: Task<Void, Never>?
    private var ackWindow: UInt32 = 0
    private var ackCount: UInt32 = 0

    /// Invoked (once) when the read loop exits with an error.
    var onClosed: (@Sendable (Error) -> Void)?

    init(connection: SpiceChannelConnection) {
        self.connection = connection
    }

    /// Begin the read loop. The link handshake must already be complete.
    func start() {
        runTask = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        Task { [connection] in await connection.close() }
    }

    // MARK: - Send

    func send(type: UInt16, payload: Data = Data()) async throws {
        try await connection.send(type: type, payload: payload)
    }

    // MARK: - Overridable

    /// Handle a channel-specific message (common flow-control is already
    /// consumed). Default: ignore.
    func handle(type: UInt16, payload: Data) async {}

    // MARK: - Loop

    /// A read blocked this long before the next message arrived means the
    /// server's previous batch is fully delivered — a natural frame boundary.
    private static let batchBoundaryNanos: UInt64 = 3_000_000   // 3 ms

    /// Called on the read loop when the connection was idle before the next
    /// message (the previous batch finished). Subclasses emit a frame here so
    /// snapshots land on server batch boundaries, not mid-batch (which tears).
    func didReachBatchBoundary() async {}

    private func runLoop() async {
        do {
            while !Task.isCancelled {
                let waitStart = DispatchTime.now().uptimeNanoseconds
                let (type, payload) = try await connection.receive()
                let idle = DispatchTime.now().uptimeNanoseconds &- waitStart
                if idle >= Self.batchBoundaryNanos { await didReachBatchBoundary() }
                await dispatch(type: type, payload: payload)
            }
        } catch {
            if !Task.isCancelled {
                log.debug("channel read loop ended: \(String(describing: error), privacy: .public)")
                onClosed?(error)
            }
        }
    }

    private func dispatch(type: UInt16, payload: Data) async {
        // Common BaseChannel messages first.
        if let common = SpiceMsg.Common(rawValue: type) {
            switch common {
            case .setAck:
                await handleSetAck(payload)
                return
            case .ping:
                await handlePing(payload)
                countTowardAck()
                return
            case .notify, .disconnecting, .migrate, .migrateData, .waitForChannels:
                countTowardAck()
                return
            }
        }
        countTowardAck()
        await handle(type: type, payload: payload)
    }

    private func countTowardAck() {
        guard ackWindow > 0 else { return }
        ackCount += 1
        if ackCount >= ackWindow {
            ackCount = 0
            Task { [weak self] in
                try? await self?.send(type: SpiceMsg.CommonClient.ack.rawValue)
            }
        }
    }

    private func handleSetAck(_ payload: Data) async {
        var r = SpiceByteReader(payload)
        guard let generation = try? r.readU32(), let window = try? r.readU32() else { return }
        ackWindow = window
        ackCount = 0
        var w = SpiceByteWriter()
        w.writeU32(generation)
        try? await send(type: SpiceMsg.CommonClient.ackSync.rawValue, payload: w.data)
    }

    private func handlePing(_ payload: Data) async {
        // PING: uint32 id, uint64 timestamp, [data...]. PONG echoes id+timestamp.
        var r = SpiceByteReader(payload)
        guard let id = try? r.readU32(), let ts = try? r.readU64() else { return }
        var w = SpiceByteWriter()
        w.writeU32(id)
        w.writeU64(ts)
        try? await send(type: SpiceMsg.CommonClient.pong.rawValue, payload: w.data)
    }
}
