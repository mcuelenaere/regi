import Foundation

/// Wire codec for PiKVM's `/api/ws` event protocol: outbound keyboard /
/// mouse events and the inbound state events the client cares about.
///
/// Every frame is `{"event_type": <type>, "event": <payload>}`. Shapes
/// match the kvmd web client exactly (`web/share/js/kvm/mouse.js`,
/// `keyboard.js`, `session.js`):
///   - key            `{"key": <W3C code>, "state": <bool>}`
///   - mouse_move      `{"to": {"x": Int, "y": Int}}`         (abs, −32768…32767)
///   - mouse_relative  `{"delta": {"x": Int, "y": Int}, "squash": true}` (±127)
///   - mouse_button    `{"button": <name>, "state": <bool>}`
///   - mouse_wheel     `{"delta": {"x": Int, "y": Int}}`      (sign·rate)
public enum PiKVMEvent {

    // MARK: - Mouse buttons

    /// PiKVM's button names. `up`/`down` are the 4th/5th buttons (the
    /// app's back/forward).
    public enum MouseButton: String, Sendable {
        case left, right, middle, up, down
    }

    // MARK: - Binary heartbeat
    //
    // `/api/ws` keepalive is a *binary* frame, not JSON: the client
    // sends a single `0` byte ~1 Hz and the server replies with a `255`
    // byte. (The handbook's JSON `ping` is stale.)
    public static let pingFrame = Data([0])
    public static let pongByte: UInt8 = 255

    // MARK: - Outbound builders

    private struct Envelope<Payload: Encodable>: Encodable {
        let eventType: String
        let event: Payload

        enum CodingKeys: String, CodingKey {
            case eventType = "event_type"
            case event
        }
    }

    private struct XY: Encodable {
        let x: Int
        let y: Int
    }

    private static func encode<P: Encodable>(_ type: String, _ payload: P) throws -> Data {
        try JSONEncoder().encode(Envelope(eventType: type, event: payload))
    }

    /// `key` event. `code` is a W3C `KeyboardEvent.code` (see `WebKeyMap`).
    public static func key(code: String, pressed: Bool) throws -> Data {
        struct Payload: Encodable { let key: String; let state: Bool }
        return try encode("key", Payload(key: code, state: pressed))
    }

    /// `mouse_move` — absolute position in PiKVM's signed range.
    public static func mouseMove(x: Int, y: Int) throws -> Data {
        struct Payload: Encodable { let to: XY }
        return try encode("mouse_move", Payload(to: XY(x: x, y: y)))
    }

    /// `mouse_relative` — signed-byte deltas (clamped to ±127 by the
    /// caller). `squash` lets the gadget coalesce a burst server-side.
    public static func mouseRelative(dx: Int, dy: Int, squash: Bool = true) throws -> Data {
        struct Payload: Encodable { let delta: XY; let squash: Bool }
        return try encode("mouse_relative", Payload(delta: XY(x: dx, y: dy), squash: squash))
    }

    /// `mouse_button` — a single button transition.
    public static func mouseButton(_ button: MouseButton, pressed: Bool) throws -> Data {
        struct Payload: Encodable { let button: String; let state: Bool }
        return try encode("mouse_button", Payload(button: button.rawValue, state: pressed))
    }

    /// `mouse_wheel` — one discrete step per axis (`sign·rate`).
    public static func mouseWheel(dx: Int, dy: Int) throws -> Data {
        struct Payload: Encodable { let delta: XY }
        return try encode("mouse_wheel", Payload(delta: XY(x: dx, y: dy)))
    }

    // MARK: - Mapping helpers

    /// Map the App layer's normalized absolute coordinate (0…32767,
    /// already letterbox-corrected) into PiKVM's signed range
    /// (−32768…32767), matching kvmd's `remap(pos, 0, w-1, -32768, 32767)`.
    public static func absoluteCoordinate(fromNormalized n: Int32) -> Int {
        let clamped = max(0, min(32767, Int(n)))
        let mapped = Int((Double(clamped) / 32767.0) * 65535.0) - 32768
        return max(-32768, min(32767, mapped))
    }

    /// Convert a signed wheel tick (the App layer's accumulated detent,
    /// from `WheelAccumulator`) into a PiKVM wheel delta: a fixed
    /// magnitude `rate` carrying the tick's sign, **inverted** to match
    /// PiKVM's axis direction — the kvmd web client likewise sends
    /// `sign · -rate`. Verified against hardware. Zero stays zero.
    public static func wheelDelta(fromTick tick: Int, rate: Int = 5) -> Int {
        if tick == 0 { return 0 }
        return tick > 0 ? -rate : rate
    }

    // MARK: - Inbound state

    /// Lightweight peek at an inbound frame's `event_type` so the client
    /// can decide whether to fully decode the `event`.
    public struct IncomingType: Decodable, Sendable {
        public let eventType: String
        enum CodingKeys: String, CodingKey { case eventType = "event_type" }
    }

    /// Decoder for the `hid` state event — the only inbound event the v1
    /// client acts on. `mouse.absolute` decides whether the default
    /// pointer mode sends `mouse_move` (true) or `mouse_relative`
    /// (false); `online` flags whether the HID gadget is attached.
    public struct HIDState: Decodable, Sendable {
        public struct Mouse: Decodable, Sendable {
            public let online: Bool?
            public let absolute: Bool?
        }
        public let online: Bool?
        public let mouse: Mouse?
    }

    private struct HIDEnvelope: Decodable {
        let event: HIDState
    }

    /// Returns the `event_type` of an inbound frame, or nil if it can't
    /// be parsed.
    public static func incomingType(_ data: Data) -> String? {
        (try? JSONDecoder().decode(IncomingType.self, from: data))?.eventType
    }

    /// Decode the `hid` state event's payload. Returns nil if `data`
    /// isn't a well-formed `hid` event.
    public static func decodeHIDState(_ data: Data) -> HIDState? {
        (try? JSONDecoder().decode(HIDEnvelope.self, from: data))?.event
    }
}
