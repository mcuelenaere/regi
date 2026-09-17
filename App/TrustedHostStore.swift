// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import OSLog
import Observation

private let log = Logger(subsystem: "app.regi.mac", category: "trusted-hosts")

/// Persistent set of hostnames the user has explicitly opted into
/// trusting for self-signed TLS certs. Keyed by **host string**, not
/// by SavedHost id, so the opt-in survives across:
///
/// - mDNS-discovered hosts that aren't saved entries
/// - re-discovery (DiscoveredHost instances are ephemeral)
/// - window close + re-open (KVMSessionWindow's @State drops)
/// - app relaunch (the set is persisted to UserDefaults)
///
/// Backed by a single `[String]` in UserDefaults — same shape as
/// HostStore. JSON would let us persist richer per-host state later
/// (e.g. cert fingerprint for TOFU pinning), but a flat set is
/// enough for the current "trust all certs from this host" policy
/// the JetKVM self-signed-cert UX needs.
///
/// Pass via `.environment(...)` from RegiApp so KVMSessionWindow
/// (which reads it when building DeviceEndpoint and writes it when
/// the user accepts the trust prompt) and any future settings UI
/// (revoke / list) all share one observable instance.
@MainActor
@Observable
final class TrustedHostStore {
    private static let storageKey = "RegiTrustedSelfSignedHosts"

    private(set) var trustedHosts: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        if let arr = defaults.stringArray(forKey: Self.storageKey) {
            self.trustedHosts = Set(arr)
        } else {
            self.trustedHosts = []
        }
        self.defaults = defaults
    }

    func isTrusted(_ host: String) -> Bool {
        trustedHosts.contains(host)
    }

    func trust(_ host: String) {
        guard !trustedHosts.contains(host) else { return }
        trustedHosts.insert(host)
        persist()
    }

    func revoke(_ host: String) {
        guard trustedHosts.remove(host) != nil else { return }
        persist()
    }

    private func persist() {
        defaults.set(Array(trustedHosts), forKey: Self.storageKey)
    }
}
