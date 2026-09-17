// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import OSLog
import Observation

private let log = Logger(subsystem: "app.regi.mac", category: "host-store")

/// Persistent ordered collection of saved hosts.
///
/// Backed by a single UserDefaults key holding a JSON-encoded array.
/// JSON instead of a dictionary so the list order matches what the
/// user sees in HostsView — they can later drag to reorder, and we
/// already serialize one Codable struct per row.
///
/// Pass via `.environment(...)` from RegiApp; both the root
/// HostsView scene and per-host KVMSessionWindow scenes need to read
/// and (in the editor's case) mutate it.
@MainActor
@Observable
final class HostStore {
    private static let storageKey = "RegiSavedHosts"

    private(set) var hosts: [SavedHost]

    init(defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([SavedHost].self, from: data)
        {
            hosts = decoded
        } else {
            hosts = []
        }
        self.defaults = defaults
    }

    private let defaults: UserDefaults

    func add(_ host: SavedHost) {
        hosts.append(host)
        persist()
    }

    func update(_ host: SavedHost) {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else {
            log.error("update: no host with id \(host.id, privacy: .public)")
            return
        }
        hosts[idx] = host
        persist()
    }

    func delete(id: SavedHost.ID) {
        hosts.removeAll(where: { $0.id == id })
        persist()
    }

    func find(id: SavedHost.ID) -> SavedHost? {
        hosts.first(where: { $0.id == id })
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(hosts)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            log.error("failed to persist hosts: \(error.localizedDescription, privacy: .public)")
        }
    }
}
