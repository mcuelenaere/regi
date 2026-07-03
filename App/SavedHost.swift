import Foundation
import JetKVMTransport

/// User-saved host entry. Backs the rows in HostsView. The id is
/// stable across restarts — KVMSessionWindow uses it to re-find the
/// host across launches when SwiftUI restores windows.
struct SavedHost: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var useTLS: Bool
    /// Device family. JetKVM is the default so entries saved before
    /// PiKVM support decode unchanged.
    var kind: DeviceKind
    /// PiKVM login user (ignored for JetKVM). Defaults to PiKVM's
    /// stock `admin`.
    var username: String

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String,
        port: Int = 80,
        useTLS: Bool = false,
        kind: DeviceKind = .jetKVM,
        username: String = "admin"
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.kind = kind
        self.username = username
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, useTLS, kind, username
    }

    // Custom decode so entries persisted before PiKVM support (no
    // `kind`/`username` keys) still load, defaulting to JetKVM.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        useTLS = try c.decode(Bool.self, forKey: .useTLS)
        kind = try c.decodeIfPresent(DeviceKind.self, forKey: .kind) ?? .jetKVM
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? "admin"
    }

    /// What to show in the list. Falls back to the host string when
    /// the user didn't pick a nickname so empty rows can't slip in.
    var displayName: String {
        name.isEmpty ? host : name
    }

    /// Connection params, sans TLS-trust opt-in — KVMSessionWindow
    /// layers the latter on at connect time by querying
    /// `TrustedHostStore` so the trust state is keyed by host string,
    /// not by SavedHost id.
    var endpoint: DeviceEndpoint {
        DeviceEndpoint(
            host: host,
            port: port,
            useTLS: useTLS,
            kind: kind,
            // PiKVM always needs a login; VNC uses it for VeNCrypt "Plain" auth
            // when present (empty → the backend picks a no-username subtype).
            username: (kind == .piKVM || kind == .vnc) ? username : nil
        )
    }

    /// Round-trippable URL string for the form's URL field. Drops the
    /// port suffix when it's the scheme default (80/443), so a typed
    /// "jetkvm.local" comes back as "http://jetkvm.local" rather than
    /// "http://jetkvm.local:80".
    var urlString: String {
        // VNC is plain RFB over TCP (no scheme). Show bare host:port; the form
        // re-parses it with the 5900 default.
        if kind == .vnc {
            return port == 5900 ? host : "\(host):\(port)"
        }
        let scheme = useTLS ? "https" : "http"
        let usingDefaultPort = (useTLS && port == 443) || (!useTLS && port == 80)
        return usingDefaultPort ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }

    /// Parse user input that's either a URL ("https://kvm.local",
    /// "http://kvm.local:8080") or a bare hostname ("kvm.local",
    /// "kvm.local:8080"). Bare hostnames default to `defaultScheme`
    /// (http for JetKVM, https for PiKVM since KVMD is TLS by default).
    /// Returns nil for unparseable / non-http(s) input.
    static func parse(
        _ raw: String,
        defaultScheme: String = "http",
        defaultPort: Int? = nil
    ) -> (host: String, port: Int, useTLS: Bool)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // URL needs a scheme to parse host/port reliably; prepend the
        // default scheme when the user didn't include one.
        let withScheme = trimmed.contains("://") ? trimmed : "\(defaultScheme)://\(trimmed)"
        guard
            let url = URL(string: withScheme),
            let host = url.host(percentEncoded: false),
            !host.isEmpty,
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return nil }
        let useTLS = scheme == "https"
        // Bare "host" (no explicit port) falls back to `defaultPort` when
        // given — VNC's 5900 — otherwise the scheme default.
        let port = url.port ?? defaultPort ?? (useTLS ? 443 : 80)
        guard port > 0, port < 65_536 else { return nil }
        return (host, port, useTLS)
    }
}
