import Foundation

/// Response from `GET /device/status` — public endpoint, returned without auth.
///
/// `isSetup == true` means the device has been initialized with an auth mode
/// (either `password` or `noPassword`). If `false`, the device is fresh and
/// requires going through the setup flow before a client can connect.
public struct DeviceStatus: Codable, Sendable, Equatable {
    public let isSetup: Bool

    public init(isSetup: Bool) {
        self.isSetup = isSetup
    }
}

/// Response from `GET /device` — protected endpoint, requires auth except in
/// `noPassword` mode where the protected middleware lets unauthenticated
/// requests through (`web.go:561-577`).
public struct LocalDevice: Codable, Sendable, Equatable {
    public let authMode: AuthMode?
    public let deviceID: String
    public let loopbackOnly: Bool

    public init(authMode: AuthMode?, deviceID: String, loopbackOnly: Bool) {
        self.authMode = authMode
        self.deviceID = deviceID
        self.loopbackOnly = loopbackOnly
    }

    private enum CodingKeys: String, CodingKey {
        case authMode
        case deviceID = "deviceId"
        case loopbackOnly
    }
}

/// Local-auth mode. `noPassword` means no auth required; `password` requires
/// `POST /auth/login-local`. Modeled as an open enum so unknown future values
/// (e.g. an empty string the server uses internally for unset) don't crash
/// decode.
public enum AuthMode: Codable, Sendable, Equatable, Hashable {
    case noPassword
    case password
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public init(rawValue: String) {
        switch rawValue {
        case "noPassword": self = .noPassword
        case "password": self = .password
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .noPassword: return "noPassword"
        case .password: return "password"
        case .unknown(let raw): return raw
        }
    }
}

/// Request body for `POST /auth/login-local`. Server replies 200 with a
/// `Set-Cookie: authToken=<uuid>; Path=/; HttpOnly` header on success.
/// 400 if the device is in `noPassword` mode (login disabled),
/// 401 on bad password, 429 on rate-limit.
public struct LoginRequest: Codable, Sendable, Equatable {
    public let password: String

    public init(password: String) {
        self.password = password
    }
}
