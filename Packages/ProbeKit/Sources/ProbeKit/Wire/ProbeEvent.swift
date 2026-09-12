import Foundation

/// Wire protocol version. Bump on any incompatible `telemetry.proto` change.
/// The probe stamps it; the driver refuses a frame it does not understand,
/// because a silently misparsed frame is worse than no frame.
public enum WireVersion {
    public static let current: UInt32 = 1
}

/// One input event as the target's `CGEventTap` saw it.
///
/// Assertions compare macOS virtual keycodes to macOS virtual keycodes — the
/// same namespace Regi sends in (`sendKeypress(virtualKeyCode:)`) — so there is
/// deliberately no identity mapping table anywhere in this package.
public struct ProbeEvent: Sendable, Equatable {
    /// Monotonic, probe-lifetime, never reused. The driver scopes every
    /// assertion to a half-open range of these.
    public var seq: UInt64
    /// `CGEventGetTimestamp` — the event's own stamp, in the mach absolute
    /// domain. The only timestamp on the wire: arrival time is probe-local and
    /// nothing downstream asserts on it.
    ///
    /// **Transmitted at microsecond resolution**, so a decoded event's value is
    /// truncated to a multiple of 1,000 ns. Nanoseconds would cost roughly two
    /// more bytes per event against a hard QR budget, and nothing asserts below
    /// millisecond scale — hold durations, settle windows and ordering are all
    /// far coarser. `FrameCodec` round-trips are exact only at µs granularity.
    public var machAbsoluteNanos: UInt64
    public var payload: Payload

    public init(seq: UInt64, machAbsoluteNanos: UInt64, payload: Payload) {
        self.seq = seq
        self.machAbsoluteNanos = machAbsoluteNanos
        self.payload = payload
    }

    public enum Payload: Sendable, Equatable {
        case key(Key)
        case flags(Flags)
        case pointer(Pointer)
        case wheel(Wheel)
        case gesture(Gesture)
        case touches([Touch])
        case diagnostic(Diagnostic)
    }

    public struct Key: Sendable, Equatable {
        public var kvk: UInt16
        public var down: Bool
        public var autorepeat: Bool
        /// Raw `CGEventFlags`, **not** `NSEvent.ModifierFlags`: the device-side
        /// bits (`NX_DEVICELSHIFTKEYMASK` and friends) are the only way to prove
        /// left/right modifier fidelity, and `NSEvent` collapses the sides.
        public var rawFlags: UInt64
        public var characters: String
        /// 0 for real hardware. Non-zero means something injected it, which on a
        /// dedicated target means the run is contaminated.
        public var sourcePID: Int32

        public init(kvk: UInt16, down: Bool, autorepeat: Bool = false,
                    rawFlags: UInt64 = 0, characters: String = "", sourcePID: Int32 = 0) {
            self.kvk = kvk; self.down = down; self.autorepeat = autorepeat
            self.rawFlags = rawFlags; self.characters = characters; self.sourcePID = sourcePID
        }
    }

    public struct Flags: Sendable, Equatable {
        public var kvk: UInt16
        public var rawFlags: UInt64
        public init(kvk: UInt16, rawFlags: UInt64) { self.kvk = kvk; self.rawFlags = rawFlags }
    }

    public struct Pointer: Sendable, Equatable {
        public var type: UInt32
        public var x: Int32
        public var y: Int32
        public var deltaX: Int32
        public var deltaY: Int32
        public var buttonNumber: UInt32
        public var clickState: UInt32
        public var sourcePID: Int32

        public init(type: UInt32, x: Int32, y: Int32, deltaX: Int32 = 0, deltaY: Int32 = 0,
                    buttonNumber: UInt32 = 0, clickState: UInt32 = 0, sourcePID: Int32 = 0) {
            self.type = type; self.x = x; self.y = y
            self.deltaX = deltaX; self.deltaY = deltaY
            self.buttonNumber = buttonNumber; self.clickState = clickState; self.sourcePID = sourcePID
        }
    }

    public struct Wheel: Sendable, Equatable {
        public var lineDeltaY: Int32
        public var lineDeltaX: Int32
        public var pointDeltaY: Int32
        public var pointDeltaX: Int32
        /// A KVM wheel detent must arrive discrete, not trackpad-continuous.
        public var isContinuous: Bool
        public var phase: UInt32
        public var sourcePID: Int32

        public init(lineDeltaY: Int32 = 0, lineDeltaX: Int32 = 0,
                    pointDeltaY: Int32 = 0, pointDeltaX: Int32 = 0,
                    isContinuous: Bool = false, phase: UInt32 = 0, sourcePID: Int32 = 0) {
            self.lineDeltaY = lineDeltaY; self.lineDeltaX = lineDeltaX
            self.pointDeltaY = pointDeltaY; self.pointDeltaX = pointDeltaX
            self.isContinuous = isContinuous; self.phase = phase; self.sourcePID = sourcePID
        }
    }

    /// Unused by Regi today. Modelled so the wire format need not change across
    /// two separately-built projects when multi-touch lands; until then these
    /// serve as negative assertions (a pinch must produce *nothing*).
    public struct Gesture: Sendable, Equatable {
        public enum Kind: UInt32, Sendable { case magnify = 1, rotate, swipe, smartMagnify, pressure }
        public var kind: Kind
        public var value: Double
        public var secondary: Double
        public var phase: UInt32
        public var stage: UInt32

        public init(kind: Kind, value: Double = 0, secondary: Double = 0,
                    phase: UInt32 = 0, stage: UInt32 = 0) {
            self.kind = kind; self.value = value; self.secondary = secondary
            self.phase = phase; self.stage = stage
        }
    }

    public struct Touch: Sendable, Equatable {
        public var identity: UInt64
        public var normX: Float
        public var normY: Float
        public var phase: UInt32
        public var type: UInt32

        public init(identity: UInt64, normX: Float, normY: Float, phase: UInt32, type: UInt32) {
            self.identity = identity; self.normX = normX; self.normY = normY
            self.phase = phase; self.type = type
        }
    }

    public struct Diagnostic: Sendable, Equatable {
        public enum Kind: UInt32, Sendable {
            case tapDisabled = 1, tapReEnabled, runWindowOpened, runWindowClosed
            case secureInputChanged, ringOverflow, permissionChanged
        }
        public var kind: Kind
        public var detail: String
        public var value: UInt64

        public init(kind: Kind, detail: String = "", value: UInt64 = 0) {
            self.kind = kind; self.detail = detail; self.value = value
        }
    }
}
