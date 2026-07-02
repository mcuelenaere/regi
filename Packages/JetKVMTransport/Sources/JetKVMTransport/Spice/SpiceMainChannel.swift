import Foundation
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "spice-main")

/// The SPICE main channel: receives INIT (session id, mouse modes) and the
/// channel list, and requests channel attachment + client (absolute) mouse
/// mode. Drives which other channels the backend opens.
final class SpiceMainChannel: SpiceChannel {
    /// Fired with the parsed INIT message (server → client, opcode 103).
    var onInit: (@Sendable (SpiceMsgMainInit) -> Void)?
    /// Fired with the channel list the server advertises.
    var onChannelsList: (@Sendable ([SpiceChannelId]) -> Void)?
    /// Fired when the server reports the active mouse mode.
    var onMouseMode: (@Sendable (SpiceProtocol.MouseMode) -> Void)?

    private(set) var initInfo: SpiceMsgMainInit?

    override func handle(type: UInt16, payload: Data) async {
        guard let msg = SpiceMsg.Main(rawValue: type) else { return }
        switch msg {
        case .initMsg:
            guard let info = try? SpiceMsgMainInit.parse(payload) else { return }
            initInfo = info
            log.debug("main INIT: session=\(info.sessionID) mouseModes=\(info.supportedMouseModes)")
            onInit?(info)
            // Ask for the channel list.
            try? await send(type: SpiceMsg.MainClient.attachChannels.rawValue)
            // Prefer client/absolute mouse mode when the server supports it.
            if info.supportedMouseModes & UInt32(SpiceProtocol.MouseMode.client.rawValue) != 0 {
                try? await send(type: SpiceMsg.MainClient.mouseModeRequest.rawValue,
                                payload: SpiceByteWriter.mouseModeRequest(.client))
            }
        case .channelsList:
            guard let list = try? SpiceMsgChannelsList.parse(payload) else { return }
            onChannelsList?(list.channels)
        case .mouseMode:
            var r = SpiceByteReader(payload)
            // supported (u16) + current (u16)
            _ = try? r.readU16()
            if let cur = try? r.readU16(), let mode = SpiceProtocol.MouseMode(rawValue: UInt32(cur)) {
                onMouseMode?(mode)
            }
        default:
            break
        }
    }
}
