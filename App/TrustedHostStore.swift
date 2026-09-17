import Foundation
import Observation

/// Persistent set of hostnames the user has explicitly opted into
/// trusting for self-signed TLS certs. Keyed by **host string**, not
/// by SavedHost id, so the opt-in survives across:
///
/// - mDNS-discovered hosts that aren't saved entries
/// - re-discovery (DiscoveredHost instances are ephemeral)
/// - window close + re-open (KVMSessionWindow's @State drops)
/// - app relaunch (the set is persisted to UserDefaults)
///
/// Backed by a single `[String]` in UserDefaults. A flat set is enough
/// for the current "trust all certs from this host" policy the JetKVM
/// self-signed-cert UX needs; richer per-host state (e.g. a cert
/// fingerprint for TOFU pinning) would want JSON instead.
///
/// Pass via `.environment(...)` from RegiApp so KVMSessionWindow
/// (which reads it when building DeviceEndpoint and writes it when
/// the user accepts the trust prompt) shares one observable instance.
@MainActor
@Observable
final class TrustedHostStore {
    private static let storageKey = "RegiTrustedSelfSignedHosts"

    private(set) var trustedHosts: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        trustedHosts = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    func isTrusted(_ host: String) -> Bool {
        trustedHosts.contains(host)
    }

    func trust(_ host: String) {
        guard trustedHosts.insert(host).inserted else { return }
        defaults.set(Array(trustedHosts), forKey: Self.storageKey)
    }
}
