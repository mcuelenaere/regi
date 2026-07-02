import Foundation

/// SPICE message opcodes and body codecs, derived from spice-common's
/// `spice.proto` (per-channel messages start at 101 and auto-increment;
/// common BaseChannel messages occupy 1–99). Only the v1 subset (video +
/// keyboard/mouse) is modelled here.
enum SpiceMsg {
    /// Common server → client (BaseChannel).
    enum Common: UInt16 {
        case migrate = 1
        case migrateData = 2
        case setAck = 3
        case ping = 4
        case waitForChannels = 5
        case disconnecting = 6
        case notify = 7
    }
    /// Common client → server.
    enum CommonClient: UInt16 {
        case ackSync = 1
        case ack = 2
        case pong = 3
        case migrateFlushMark = 4
        case migrateData = 5
        case disconnecting = 6
    }
    /// Main channel server → client.
    enum Main: UInt16 {
        case migrateBegin = 101
        case migrateCancel = 102
        case initMsg = 103
        case channelsList = 104
        case mouseMode = 105
        case multiMediaTime = 106
        case agentConnected = 107
        case agentDisconnected = 108
        case agentData = 109
        case agentToken = 110
        case name = 113
        case uuid = 114
    }
    /// Main channel client → server.
    enum MainClient: UInt16 {
        case clientInfo = 101
        case attachChannels = 104
        case mouseModeRequest = 105
        case agentStart = 106
    }
    /// Inputs channel client → server.
    enum InputsClient: UInt16 {
        case keyDown = 101
        case keyUp = 102
        case keyModifiers = 103
        case mouseMotion = 111
        case mousePosition = 112
        case mousePress = 113
        case mouseRelease = 114
    }
    /// Inputs channel server → client.
    enum InputsServer: UInt16 {
        case initMsg = 101
        case keyModifiers = 102
        case mouseMotionAck = 111
    }

    /// SPICE mouse button ids (`enum8 mouse_button`).
    enum MouseButton: UInt8 {
        case invalid = 0, left = 1, middle = 2, right = 3, up = 4, down = 5
    }
    /// SPICE `flags16 mouse_button_mask` bits.
    struct ButtonMask {
        static let left: UInt16 = 1
        static let middle: UInt16 = 2
        static let right: UInt16 = 4
    }
}

/// `SpiceMsgMainInit` (main INIT, opcode 103): eight u32 fields.
struct SpiceMsgMainInit: Equatable {
    var sessionID: UInt32
    var displayChannelsHint: UInt32
    var supportedMouseModes: UInt32
    var currentMouseMode: UInt32
    var agentConnected: UInt32
    var agentTokens: UInt32
    var multiMediaTime: UInt32
    var ramHint: UInt32

    static func parse(_ data: Data) throws -> SpiceMsgMainInit {
        var r = SpiceByteReader(data)
        return SpiceMsgMainInit(
            sessionID: try r.readU32(),
            displayChannelsHint: try r.readU32(),
            supportedMouseModes: try r.readU32(),
            currentMouseMode: try r.readU32(),
            agentConnected: try r.readU32(),
            agentTokens: try r.readU32(),
            multiMediaTime: try r.readU32(),
            ramHint: try r.readU32()
        )
    }
}

/// One entry in the main CHANNELS_LIST (`ChannelId`: type u8, id u8).
struct SpiceChannelId: Equatable {
    var type: UInt8
    var id: UInt8
}

/// `SpiceMsgChannels` (main CHANNELS_LIST, opcode 104).
struct SpiceMsgChannelsList: Equatable {
    var channels: [SpiceChannelId]

    static func parse(_ data: Data) throws -> SpiceMsgChannelsList {
        var r = SpiceByteReader(data)
        let count = try r.readU32()
        var channels: [SpiceChannelId] = []
        for _ in 0..<count {
            channels.append(SpiceChannelId(type: try r.readU8(), id: try r.readU8()))
        }
        return SpiceMsgChannelsList(channels: channels)
    }
}

// MARK: - Client message body encoders

extension SpiceByteWriter {
    /// key_down / key_up body: uint32 code. Extended (0xE0-prefixed) scancodes
    /// are encoded as `0xe0 | (code << 8)`, matching spice-gtk.
    static func keyCode(_ scancode: SpiceScancode) -> Data {
        var w = SpiceByteWriter()
        w.writeU32(scancode.wireCode)
        return w.data
    }

    /// mouse_position body: x, y (u32), buttons (u16 mask), display_id (u8).
    static func mousePosition(x: UInt32, y: UInt32, buttons: UInt16, displayID: UInt8) -> Data {
        var w = SpiceByteWriter()
        w.writeU32(x); w.writeU32(y); w.writeU16(buttons); w.writeU8(displayID)
        return w.data
    }

    /// mouse_motion body: dx, dy (i32), buttons (u16 mask).
    static func mouseMotion(dx: Int32, dy: Int32, buttons: UInt16) -> Data {
        var w = SpiceByteWriter()
        w.writeI32(dx); w.writeI32(dy); w.writeU16(buttons)
        return w.data
    }

    /// mouse_press / mouse_release body: button (u8), buttons (u16 mask).
    static func mouseButton(_ button: SpiceMsg.MouseButton, buttons: UInt16) -> Data {
        var w = SpiceByteWriter()
        w.writeU8(button.rawValue); w.writeU16(buttons)
        return w.data
    }

    /// mouse_mode_request body: mode (u16 flags).
    static func mouseModeRequest(_ mode: SpiceProtocol.MouseMode) -> Data {
        var w = SpiceByteWriter()
        w.writeU16(UInt16(mode.rawValue))
        return w.data
    }

    /// client_info body: cache_size (u64).
    static func clientInfo(cacheSize: UInt64) -> Data {
        var w = SpiceByteWriter()
        w.writeU64(cacheSize)
        return w.data
    }
}
