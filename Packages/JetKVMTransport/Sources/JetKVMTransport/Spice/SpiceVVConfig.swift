import Foundation

/// A parsed Proxmox / oVirt virt-viewer connection file (`.vv`). This is the
/// INI file the Proxmox UI hands out for "Console → SPICE": it carries the
/// node address, the SPICE (TLS) port, a one-time ticket (`password`), the
/// cluster CA, and the expected certificate `host-subject`.
///
/// ```
/// [virt-viewer]
/// type=spice
/// host=192.0.2.10
/// tls-port=61000
/// password=<one-time ticket>
/// proxy=http://pve.example.com:3128
/// host-subject=OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve.example.com
/// ca=-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n
/// ```
public struct SpiceVVConfig: Equatable {
    public var type: String?
    public var host: String?
    public var port: UInt16?
    public var tlsPort: UInt16?
    /// One-time SPICE ticket, used as the ticket-auth password. Short-lived.
    public var password: String?
    /// `http://host:port` proxy, when the node isn't directly reachable.
    public var proxy: String?
    /// Expected certificate subject, e.g. "OU=...,O=...,CN=node.fqdn".
    public var hostSubject: String?
    /// PEM CA bundle (newlines already unescaped).
    public var caPEM: String?

    public init() {}

    public enum Error: Swift.Error, Equatable {
        case missingHost
        case missingPort
    }

    /// Parse a `.vv` INI. Keys are matched case-insensitively; only the
    /// `[virt-viewer]` section is read. The `ca` value's literal `\n`
    /// escapes are turned into real newlines.
    public static func parse(_ text: String) -> SpiceVVConfig {
        var config = SpiceVVConfig()
        var inSection = false

        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inSection = line.lowercased() == "[virt-viewer]"
                continue
            }
            guard inSection, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: eq)...])

            switch key {
            case "type": config.type = value
            case "host": config.host = value
            case "port": config.port = UInt16(value)
            case "tls-port": config.tlsPort = UInt16(value)
            case "password": config.password = value
            case "proxy": config.proxy = value.isEmpty ? nil : value
            case "host-subject": config.hostSubject = value
            case "ca": config.caPEM = value.replacingOccurrences(of: "\\n", with: "\n")
            default: break
            }
        }
        return config
    }

    /// The port to connect to and whether it is TLS. Prefers the TLS port.
    public func resolvedEndpoint() throws -> (host: String, port: UInt16, useTLS: Bool) {
        guard let host, !host.isEmpty else { throw Error.missingHost }
        if let tlsPort, tlsPort != 0 { return (host, tlsPort, true) }
        if let port, port != 0 { return (host, port, false) }
        throw Error.missingPort
    }
}
