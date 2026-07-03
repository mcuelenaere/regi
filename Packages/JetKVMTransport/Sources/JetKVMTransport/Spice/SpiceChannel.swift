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

    /// Monotonic time (ns) at which the read loop began waiting for the next
    /// message, or 0 while it is actively processing one. The display channel
    /// uses this to emit a frame only once the server has gone quiet (read loop
    /// blocked) — never mid-batch, which would show a half-drawn frame. A read
    /// of a naturally-aligned UInt64 is atomic on the platforms we target.
    private(set) var receiveBlockedSinceNanos: UInt64 = 0

    /// Worst read-loop idle (ns) seen right after hitting the ACK window since
    /// the last reset — i.e. the effective flow-control round-trip that gates
    /// large redraws. Diagnostic; drained by the stats poller.
    private(set) var ackStallMaxNanos: UInt64 = 0
    func resetAckStallStat() { ackStallMaxNanos = 0 }

    private func runLoop() async {
        do {
            while !Task.isCancelled {
                let wasAtAckWindow = lastMessageHitAckWindow
                let blockStart = DispatchTime.now().uptimeNanoseconds
                receiveBlockedSinceNanos = blockStart
                let header = try await connection.receiveMessageHeader()
                // Header in hand: everything from here (body bytes, decode,
                // blit) is mid-message — the rest of this frame is still in
                // flight, so it must read as "busy", never as a boundary. A
                // multi-packet body stalling on the network otherwise looks
                // idle and gets presented half-applied.
                receiveBlockedSinceNanos = 0
                if wasAtAckWindow {
                    let idle = DispatchTime.now().uptimeNanoseconds &- blockStart
                    if idle > ackStallMaxNanos { ackStallMaxNanos = idle }
                }
                let payload = try await connection.receiveMessageBody(header)
                await dispatch(type: header.type, payload: payload)
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

    /// True when the message just processed was the one that hit the ACK
    /// window (so we sent an ACK). A read-loop idle right after this is almost
    /// always the server stalled awaiting that ACK to keep sending the *same*
    /// frame — the display channel uses this to avoid presenting mid-frame.
    private(set) var lastMessageHitAckWindow = false

    private func countTowardAck() {
        guard ackWindow > 0 else { lastMessageHitAckWindow = false; return }
        ackCount += 1
        if ackCount >= ackWindow {
            ackCount = 0
            lastMessageHitAckWindow = true
            // High priority + noDelay socket: get the ACK on the wire ASAP so
            // the server's flow-control stall is only the raw round-trip.
            Task(priority: .high) { [weak self] in
                try? await self?.send(type: SpiceMsg.CommonClient.ack.rawValue)
            }
        } else {
            lastMessageHitAckWindow = false
        }
    }

    private func handleSetAck(_ payload: Data) async {
        var r = SpiceByteReader(payload)
        guard let generation = try? r.readU32(), let window = try? r.readU32() else { return }
        ackWindow = window
        ackCount = 0
        log.notice("SPICE channel \(self.connection.channelType.rawValue) SET_ACK window=\(window)")
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
