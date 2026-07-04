import Foundation

/// One frame on the JetKVM `hidrpc` (or `hidrpc-unreliable-*`) data
/// channel.
///
/// Wire format is `[type:u8][payload...]` with multi-byte integers in
/// big-endian order. Verified against the server-side opcode list in
/// `internal/hidrpc/hidrpc.go:13-25` and per-message payload shapes in
/// `internal/hidrpc/message.go`.
///
/// Opcode 0x04 (`WheelReport`) is firmware-version-gated. JetKVM
/// firmware >= 0.5.9 dispatches it; older firmware silently drops
/// unknown opcodes. `Session.sendWheelReport` checks
/// `DeviceMetadata.firmwareIsAtLeast(...)` and falls back to the
/// JSON-RPC `wheelReport` method when the binary opcode isn't
/// supported.
public enum HIDRPCMessage: Sendable, Equatable {
    /// HID-RPC protocol version. The server enforces a handshake on the
    /// `hidrpc` channel before it'll act on any input.
    public static let protocolVersion: UInt8 = 0x01

    /// Convenience: the standard handshake the client must send first.
    public static let standardHandshake = HIDRPCMessage.handshake(version: protocolVersion)

    /// Maximum number of simultaneously-pressed keys reportable in one
    /// keyboard report (per `internal/hidrpc/message.go:107`).
    public static let maxKeyboardReportKeys = 6

    // MARK: - Client → server

    /// 0x01. Required first frame on the `hidrpc` channel.
    case handshake(version: UInt8)

    /// 0x02. Full keyboard report: modifier byte + up to
    /// `maxKeyboardReportKeys` USB-HID Usage IDs.
    case keyboardReport(modifier: UInt8, keys: [UInt8])

    /// 0x03. Absolute mouse pointer position. X/Y are normalized to
    /// 0..32767 over the full video frame; buttons is the boot-mouse
    /// button bitmask.
    case pointerReport(x: Int32, y: Int32, buttons: UInt8)

    /// 0x04. Scroll-wheel detents. `deltaY` is the vertical wheel,
    /// `deltaX` the horizontal one — both signed bytes. Firmware-
    /// gated; see the type-doc above.
    case wheelReport(deltaY: Int8, deltaX: Int8)

    /// 0x05. Single key press/release.
    case keypressReport(key: UInt8, pressed: Bool)

    /// 0x06. Relative mouse delta. dx/dy are signed bytes; clamp/chunk
    /// larger movements into multiple frames at the call site.
    case mouseReport(dx: Int8, dy: Int8, buttons: UInt8)

    /// 0x07. Multi-step macro / paste. Each step holds modifier + 6
    /// keys + delay (ms).
    case keyboardMacroReport(isPaste: Bool, steps: [KeyboardMacroStep])

    /// 0x08. Cancel an in-progress macro. No payload.
    case cancelKeyboardMacroReport

    /// 0x09. Keep-alive emitted while a key is held so the gadget
    /// driver doesn't auto-release. No payload.
    case keypressKeepAliveReport

    // MARK: - Server → client

    /// 0x32. Host's keyboard LED state (Caps/Num/Scroll).
    case keyboardLedState(ledByte: UInt8)

    /// 0x33. Host's view of currently-held keys. Modifier byte + N USB
    /// HID Usage IDs.
    case keydownState(modifier: UInt8, keys: [UInt8])

    /// 0x34. Macro execution state.
    case keyboardMacroState(active: Bool, isPaste: Bool)
}

/// One step of a `keyboardMacroReport`.
public struct KeyboardMacroStep: Sendable, Equatable {
    /// Fixed key buffer size per server-side `HidKeyBufferSize`
    /// (`internal/hidrpc/message.go:107`).
    public static let keysSize = 6

    public let modifier: UInt8
    public let keys: [UInt8]
    public let delayMs: UInt16

    public init(modifier: UInt8, keys: [UInt8], delayMs: UInt16) {
        precondition(
            keys.count == KeyboardMacroStep.keysSize,
            "KeyboardMacroStep keys must be exactly \(KeyboardMacroStep.keysSize) bytes; got \(keys.count)"
        )
        self.modifier = modifier
        self.keys = keys
        self.delayMs = delayMs
    }
}

public enum HIDRPCDecodingError: Error, Sendable, Equatable {
    /// Empty data (no opcode byte).
    case empty
    /// Opcode byte didn't match any known message type.
    case unknownType(UInt8)
    /// Payload too short for the message type.
    case truncated(messageType: UInt8, expectedAtLeast: Int, actual: Int)
    /// Payload is structurally invalid (wrong total size given header).
    case malformed(messageType: UInt8, reason: String)
}

extension HIDRPCMessage {
    /// The type byte (opcode) for this message variant.
    public var typeByte: UInt8 {
        switch self {
        case .handshake: return 0x01
        case .keyboardReport: return 0x02
        case .pointerReport: return 0x03
        case .wheelReport: return 0x04
        case .keypressReport: return 0x05
        case .mouseReport: return 0x06
        case .keyboardMacroReport: return 0x07
        case .cancelKeyboardMacroReport: return 0x08
        case .keypressKeepAliveReport: return 0x09
        case .keyboardLedState: return 0x32
        case .keydownState: return 0x33
        case .keyboardMacroState: return 0x34
        }
    }

    /// Wire-format bytes ready to send on the data channel.
    public var wireFormat: Data {
        var out = Data()
        out.append(typeByte)
        switch self {
        case .handshake(let version):
            out.append(version)
        case .keyboardReport(let modifier, let keys):
            out.append(modifier)
            out.append(contentsOf: keys)
        case .pointerReport(let x, let y, let buttons):
            out.appendBigEndian(x)
            out.appendBigEndian(y)
            out.append(buttons)
        case .wheelReport(let deltaY, let deltaX):
            out.append(UInt8(bitPattern: deltaY))
            out.append(UInt8(bitPattern: deltaX))
        case .keypressReport(let key, let pressed):
            out.append(key)
            out.append(pressed ? 0x01 : 0x00)
        case .mouseReport(let dx, let dy, let buttons):
            out.append(UInt8(bitPattern: dx))
            out.append(UInt8(bitPattern: dy))
            out.append(buttons)
        case .keyboardMacroReport(let isPaste, let steps):
            out.append(isPaste ? 0x01 : 0x00)
            out.appendBigEndian(UInt32(steps.count))
            for step in steps {
                out.append(step.modifier)
                out.append(contentsOf: step.keys)
                out.appendBigEndian(step.delayMs)
            }
        case .cancelKeyboardMacroReport, .keypressKeepAliveReport:
            break // no payload
        case .keyboardLedState(let ledByte):
            out.append(ledByte)
        case .keydownState(let modifier, let keys):
            out.append(modifier)
            out.append(contentsOf: keys)
        case .keyboardMacroState(let active, let isPaste):
            out.append(active ? 0x01 : 0x00)
            out.append(isPaste ? 0x01 : 0x00)
        }
        return out
    }

    /// Parse a wire-format frame. Throws if the bytes don't form a
    /// valid message of any known type.
    public init(wireFormat data: Data) throws {
        guard let firstByte = data.first else { throw HIDRPCDecodingError.empty }
        let type = firstByte
        let payload: [UInt8] = Array(data.dropFirst())

        switch type {
        case 0x01:
            try ensure(payload, atLeast: 1, type: type)
            self = .handshake(version: payload[0])

        case 0x02:
            try ensure(payload, atLeast: 1, type: type)
            self = .keyboardReport(modifier: payload[0], keys: Array(payload.dropFirst()))

        case 0x03:
            guard payload.count == 9 else {
                throw HIDRPCDecodingError.truncated(messageType: type, expectedAtLeast: 9, actual: payload.count)
            }
            self = .pointerReport(
                x: Int32(bigEndianAt: payload, offset: 0),
                y: Int32(bigEndianAt: payload, offset: 4),
                buttons: payload[8]
            )

        case 0x04:
            // Server validates `len(m.d) != 2` strictly
            // (internal/hidrpc/message.go:209).
            guard payload.count == 2 else {
                throw HIDRPCDecodingError.truncated(messageType: type, expectedAtLeast: 2, actual: payload.count)
            }
            self = .wheelReport(
                deltaY: Int8(bitPattern: payload[0]),
                deltaX: Int8(bitPattern: payload[1])
            )

        case 0x05:
            try ensure(payload, atLeast: 2, type: type)
            self = .keypressReport(key: payload[0], pressed: payload[1] != 0)

        case 0x06:
            try ensure(payload, atLeast: 3, type: type)
            self = .mouseReport(
                dx: Int8(bitPattern: payload[0]),
                dy: Int8(bitPattern: payload[1]),
                buttons: payload[2]
            )

        case 0x07:
            try ensure(payload, atLeast: 5, type: type)
            let isPaste = payload[0] != 0
            let stepCount = UInt32(bigEndianAt: payload, offset: 1)
            let stepBytes = 1 + KeyboardMacroStep.keysSize + 2
            let expected = 5 + Int(stepCount) * stepBytes
            guard payload.count == expected else {
                throw HIDRPCDecodingError.malformed(
                    messageType: type,
                    reason: "expected \(expected) bytes for \(stepCount) steps, got \(payload.count)"
                )
            }
            var steps: [KeyboardMacroStep] = []
            steps.reserveCapacity(Int(stepCount))
            for i in 0..<Int(stepCount) {
                let stepStart = 5 + i * stepBytes
                let modifier = payload[stepStart]
                let keys = Array(payload[(stepStart + 1)..<(stepStart + 1 + KeyboardMacroStep.keysSize)])
                let delay = UInt16(bigEndianAt: payload, offset: stepStart + 1 + KeyboardMacroStep.keysSize)
                steps.append(KeyboardMacroStep(modifier: modifier, keys: keys, delayMs: delay))
            }
            self = .keyboardMacroReport(isPaste: isPaste, steps: steps)

        case 0x08:
            self = .cancelKeyboardMacroReport

        case 0x09:
            self = .keypressKeepAliveReport

        case 0x32:
            try ensure(payload, atLeast: 1, type: type)
            self = .keyboardLedState(ledByte: payload[0])

        case 0x33:
            try ensure(payload, atLeast: 1, type: type)
            self = .keydownState(modifier: payload[0], keys: Array(payload.dropFirst()))

        case 0x34:
            try ensure(payload, atLeast: 2, type: type)
            self = .keyboardMacroState(active: payload[0] != 0, isPaste: payload[1] != 0)

        default:
            throw HIDRPCDecodingError.unknownType(type)
        }
    }
}

private func ensure(_ payload: [UInt8], atLeast minLength: Int, type: UInt8) throws {
    guard payload.count >= minLength else {
        throw HIDRPCDecodingError.truncated(
            messageType: type, expectedAtLeast: minLength, actual: payload.count
        )
    }
}

// MARK: - Big-endian helpers

extension Data {
    fileprivate mutating func appendBigEndian(_ value: Int32) {
        appendBigEndian(UInt32(bitPattern: value))
    }

    fileprivate mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    fileprivate mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}

extension Int32 {
    fileprivate init(bigEndianAt bytes: [UInt8], offset: Int) {
        let unsigned = UInt32(bigEndianAt: bytes, offset: offset)
        self = Int32(bitPattern: unsigned)
    }
}

extension UInt32 {
    fileprivate init(bigEndianAt bytes: [UInt8], offset: Int) {
        self = (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}

extension UInt16 {
    fileprivate init(bigEndianAt bytes: [UInt8], offset: Int) {
        self = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }
}
