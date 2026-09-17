// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import OSLog
import Security

private let log = Logger(subsystem: "app.regi.mac", category: "vault")

/// Thin wrapper over the macOS Keychain for storing JetKVM device
/// passwords keyed by hostname.
///
/// Why keyed by host and not by device ID: at the time the user types
/// the connect form, we don't yet know the device ID — we get it
/// after the first authenticated `GET /device` round-trip. The host
/// string is what the user typed and what they'll type next time, so
/// it's the natural lookup key.
///
/// The downside is that two devices reachable via the same hostname
/// (e.g., the user moves their JetKVM and re-uses `jetkvm.local`)
/// would share an entry. Acceptable trade — extremely rare, and the
/// failure mode is just "saved password doesn't work, prompt anyway."
enum PasswordVault {
    /// Generic-password service identifier for our entries. Visible
    /// in Keychain Access if the user wants to inspect.
    static let service = "app.regi.mac.password"

    /// Look up a saved password for the given host. nil if there
    /// isn't one (or if Keychain returned an unexpected error).
    static func load(for host: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let password = String(data: data, encoding: .utf8)
            else {
                log.error("keychain returned non-UTF8 password for \(host, privacy: .public); ignoring")
                return nil
            }
            return password
        case errSecItemNotFound:
            return nil
        default:
            log.error("keychain load for \(host, privacy: .public) failed: OSStatus \(status, privacy: .public)")
            return nil
        }
    }

    /// Save (or replace) the password for the given host. Errors are
    /// logged but don't throw — the calling UI will surface "we
    /// couldn't remember it" via the user just having to type again
    /// next time.
    static func save(_ password: String, for host: String) {
        // Replace any existing entry first. Keychain doesn't have a
        // single "upsert" so we delete-then-add.
        delete(for: host)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecValueData as String: Data(password.utf8),
            // Sync to iCloud Keychain off — this is per-device by design.
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            log.error("keychain save for \(host, privacy: .public) failed: OSStatus \(status, privacy: .public)")
        }
    }

    /// Remove any saved password for the given host. Idempotent.
    static func delete(for host: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("keychain delete for \(host, privacy: .public) failed: OSStatus \(status, privacy: .public)")
        }
    }
}
