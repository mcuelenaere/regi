import Foundation

/// Wire types for the JSON-RPC methods the macOS client uses.
/// Source-of-truth is the server-side handlers in
/// `jsonrpc.go:1243` and the Go structs they return.

// MARK: - ATX power

/// Action argument for `setATXPowerAction`. Note the kebab-case wire
/// values — server-side switch is at `jsonrpc.go:793-808`.
public enum ATXPowerAction: String, Codable, Sendable, CaseIterable {
    /// 200ms power-button press. Triggers a clean shutdown / power-on
    /// from most BIOS/UEFI ATX implementations.
    case powerShort = "power-short"
    /// 5-second power-button hold. Force-power-off.
    case powerLong = "power-long"
    /// 200ms reset-button press.
    case reset = "reset"
}

/// Result of `getATXState` — the host's front-panel LED states.
public struct ATXState: Codable, Sendable, Equatable {
    public let power: Bool
    public let hdd: Bool

    public init(power: Bool, hdd: Bool) {
        self.power = power
        self.hdd = hdd
    }
}

// MARK: - Video codec preference

/// Argument and return type for the codec preference RPCs.
public enum VideoCodecPreference: String, Codable, Sendable, CaseIterable {
    case auto
    case h264
    case h265
}

// MARK: - Video state

/// Streaming state of the video pipeline. Wire format is `uint8`
/// per `internal/native/native.go:47-53`. Modeled as an open enum so
/// future server-side values don't crash decode.
public enum VideoStreamingStatus: Sendable, Equatable {
    case inactive
    case active
    case stopping
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .inactive
        case 1: self = .active
        case 2: self = .stopping
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .inactive: return 0
        case .active:   return 1
        case .stopping: return 2
        case .unknown(let v): return v
        }
    }
}

extension VideoStreamingStatus: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(UInt8.self)
        self = VideoStreamingStatus(rawValue: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Result of `getVideoState`. Mirrors `internal/native/video.go`.
public struct VideoState: Codable, Sendable, Equatable {
    public let ready: Bool
    public let streaming: VideoStreamingStatus
    public let error: String?
    public let width: Int
    public let height: Int
    public let fps: Double

    public init(
        ready: Bool,
        streaming: VideoStreamingStatus,
        error: String? = nil,
        width: Int,
        height: Int,
        fps: Double
    ) {
        self.ready = ready
        self.streaming = streaming
        self.error = error
        self.width = width
        self.height = height
        self.fps = fps
    }
}

// MARK: - Failsafe

/// Payload of the `failsafeMode` server-pushed notification
/// (`failsafe.go:26-29`). When `active` is true the device is in
/// failsafe mode and the user should be alerted; `reason` is a
/// human-readable string for the banner.
public struct FailsafeModeNotification: Codable, Sendable, Equatable {
    public let active: Bool
    public let reason: String

    public init(active: Bool, reason: String) {
        self.active = active
        self.reason = reason
    }
}
