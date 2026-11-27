// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// One frame the client sends on the JetKVM `hidrpc` data channel.
///
/// Wire format is `[type:u8][payload...]` with multi-byte integers in
/// big-endian order. Verified against the server-side opcode list in
/// `internal/hidrpc/hidrpc.go:13-25` and per-message payload shapes in
/// `internal/hidrpc/message.go`. Only the opcodes Regi sends are here; what
/// the device pushes back on this channel (LED, keydown and macro state) is
/// ignored.
///
/// Opcode 0x04 (`WheelReport`) is not dispatched by firmware 0.5.9/0.5.10
/// (it logs "unknown HID RPC message type"), so scroll uses JSON-RPC
/// `wheelReport` there. Firmware 0.5.11 (jetkvm/kvm#1462) removed that
/// method and accepts only this opcode; JetKVMBackend picks by firmware version.
public enum HIDRPCMessage: Sendable, Equatable {
    /// HID-RPC protocol version. The server enforces a handshake on the
    /// `hidrpc` channel before it'll act on any input.
    public static let protocolVersion: UInt8 = 0x01

    /// Convenience: the standard handshake the client must send first.
    public static let standardHandshake = HIDRPCMessage.handshake(version: protocolVersion)

    /// 0x01. Required first frame on the `hidrpc` channel.
    case handshake(version: UInt8)

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

    /// 0x09. Keep-alive emitted while a key is held so the gadget
    /// driver doesn't auto-release. No payload.
    case keypressKeepAliveReport

    /// Wire-format bytes ready to send on the data channel.
    public var wireFormat: Data {
        switch self {
        case .handshake(let version):
            return Data([0x01, version])
        case .pointerReport(let x, let y, let buttons):
            var out = Data([0x03])
            withUnsafeBytes(of: x.bigEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: y.bigEndian) { out.append(contentsOf: $0) }
            out.append(buttons)
            return out
        case .wheelReport(let deltaY, let deltaX):
            return Data([0x04, UInt8(bitPattern: deltaY), UInt8(bitPattern: deltaX)])
        case .keypressReport(let key, let pressed):
            return Data([0x05, key, pressed ? 0x01 : 0x00])
        case .mouseReport(let dx, let dy, let buttons):
            return Data([0x06, UInt8(bitPattern: dx), UInt8(bitPattern: dy), buttons])
        case .keypressKeepAliveReport:
            return Data([0x09])
        }
    }
}
