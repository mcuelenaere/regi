import Foundation
import JetKVMTransport
import OSLog
import Observation

private let log = Logger(subsystem: "app.regi.mac", category: "discovery")

/// Bonjour browser for KVM devices on the local network. Lives for the
/// app's lifetime; a single shared instance is injected via
/// `.environment(...)` from RegiApp.
///
/// Browses two service types in parallel — `_jetkvm._tcp` (JetKVM, see
/// `internal/mdns/mdns.go` upstream) and `_pikvm._tcp` (PiKVM's Avahi
/// advertisement, see `scripts/kvmd-bootconfig`). Each found instance is
/// resolved with NetService (NWBrowser doesn't expose hostname/port/TXT
/// in one shot); the resolved service's `type` tells us which family it
/// is.
///
/// Implementation notes:
/// - Uses NetServiceBrowser + NetService rather than NWBrowser
///   because the former gives us hostname, port, and TXT in a single
///   resolve callback. NWBrowser is "more modern" but its TXT path
///   requires a separate NWConnection dance.
/// - Delegate callbacks land on a non-isolated NSObject method;
///   we hop to the main actor before mutating state.
/// - Exposes `hosts` as an `@Observable` array so SwiftUI views
///   re-render automatically when the LAN composition changes.
@MainActor
@Observable
final class DeviceDiscovery: NSObject {
    private(set) var hosts: [DiscoveredHost] = []

    private let jetBrowser = NetServiceBrowser()
    private let piBrowser = NetServiceBrowser()
    /// In-flight resolves keyed by service instance name. We hold
    /// strong references so NetService doesn't dealloc mid-resolve.
    private var pendingResolves: [String: NetService] = [:]

    override init() {
        super.init()
        jetBrowser.delegate = self
        piBrowser.delegate = self
    }

    /// Starts browsing for `_jetkvm._tcp` and `_pikvm._tcp` services.
    /// Idempotent — calling while already running is a no-op
    /// (NetServiceBrowser handles that itself).
    func start() {
        log.info("starting Bonjour browsers for _jetkvm._tcp + _pikvm._tcp")
        jetBrowser.searchForServices(ofType: "_jetkvm._tcp", inDomain: "")
        piBrowser.searchForServices(ofType: "_pikvm._tcp", inDomain: "")
    }

    /// Stops browsing and clears all results. Useful for tests; in
    /// regular runtime we leave discovery active app-wide.
    func stop() {
        log.info("stopping Bonjour browsers")
        jetBrowser.stop()
        piBrowser.stop()
        for (_, service) in pendingResolves {
            service.stop()
        }
        pendingResolves.removeAll()
        hosts.removeAll()
    }

    private func parseTXT(_ data: Data?) -> [String: String] {
        guard let data else { return [:] }
        let raw = NetService.dictionary(fromTXTRecord: data)
        var result: [String: String] = [:]
        for (key, valueData) in raw {
            if let value = String(data: valueData, encoding: .utf8) {
                result[key] = value
            }
        }
        return result
    }
}

extension DeviceDiscovery: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let captured = service
        Task { @MainActor [weak self] in
            self?.startResolving(captured)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        let name = service.name
        Task { @MainActor [weak self] in
            self?.removeService(named: name)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        log.error("browser didNotSearch: \(errorDict, privacy: .public)")
    }

    @MainActor
    private func startResolving(_ service: NetService) {
        let name = service.name
        log.debug("found service \(name, privacy: .public); resolving")
        service.delegate = self
        service.resolve(withTimeout: 5)
        pendingResolves[name] = service
    }

    @MainActor
    private func removeService(named name: String) {
        log.debug("service gone: \(name, privacy: .public)")
        if let svc = pendingResolves.removeValue(forKey: name) {
            svc.stop()
        }
        hosts.removeAll { $0.instanceName == name }
    }
}

extension DeviceDiscovery: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let name = sender.name
        let type = sender.type
        let hostName = sender.hostName
        let port = sender.port
        let txtData = sender.txtRecordData()
        Task { @MainActor [weak self] in
            self?.resolved(
                name: name,
                serviceType: type,
                hostName: hostName,
                port: port,
                txtData: txtData
            )
        }
    }

    nonisolated func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        let name = sender.name
        Task { @MainActor [weak self] in
            log.error("\(name, privacy: .public) didNotResolve: \(errorDict, privacy: .public)")
            self?.pendingResolves.removeValue(forKey: name)
        }
    }

    @MainActor
    private func resolved(
        name: String,
        serviceType: String,
        hostName: String?,
        port: Int,
        txtData: Data?
    ) {
        defer { pendingResolves.removeValue(forKey: name) }
        guard let hostName, port > 0 else { return }
        // Bonjour gives us "jetkvm-abc.local." with a trailing dot.
        let cleanHost = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        let txt = parseTXT(txtData)
        // `sender.type` is the registration type with a trailing dot,
        // e.g. "_pikvm._tcp.".
        let kind: DeviceKind = serviceType.contains("_pikvm._tcp") ? .piKVM : .jetKVM
        let useTLS = port == 443 || txt["protocol"]?.lowercased() == "https"

        let deviceID: String?
        let version: String?
        let isSetup: Bool
        switch kind {
        case .jetKVM:
            deviceID = txt["id"]
            version = txt["version"]
            isSetup = (txt["setup"] ?? "true") != "false"
        case .piKVM:
            // PiKVM advertises serial/model/board but no version or
            // setup flag; treat it as always reachable.
            deviceID = txt["serial"]
            version = nil
            isSetup = true
        }

        let entry = DiscoveredHost(
            instanceName: name,
            host: cleanHost,
            port: port,
            useTLS: useTLS,
            kind: kind,
            deviceID: deviceID,
            version: version,
            isSetup: isSetup
        )
        // Replace any existing entry for the same instance name so
        // re-advertisements (e.g. setup= flipping) update in place.
        hosts.removeAll { $0.instanceName == name }
        hosts.append(entry)
        hosts.sort { $0.instanceName < $1.instanceName }
        log.info("resolved \(kind.rawValue, privacy: .public) \(name, privacy: .public) -> \(cleanHost, privacy: .public):\(port, privacy: .public)")
    }
}
