import FileProvider
import Foundation
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "fileprovider")

/// Owns the File Provider domain that backs files pasted from the host.
///
/// Why a File Provider at all: a lazily-promised `public.file-url` on the
/// pasteboard does not stay lazy. Universal Clipboard force-resolves that
/// flavour roughly 100ms after every clipboard change so it can mirror the
/// clipboard to the user's other devices — `pboard` logs it under
/// `CFPasteboard:remote` — and the provider is asked exactly once, with no
/// second chance. So promising through the pasteboard always means
/// transferring, whether or not anyone pastes.
///
/// A File Provider moves the laziness somewhere the OS actually honours
/// it: the pasteboard carries an ordinary `file:` URL into our domain,
/// which costs a path to resolve rather than the file, and the bytes are
/// fetched only when something genuinely opens it.
enum ClipboardFileProviderDomain {

    static let identifier = NSFileProviderDomainIdentifier("app.regi.mac.clipboard")

    /// Register the domain, replacing any left over from a previous run.
    /// Returns nil on success, or the error to explain why not.
    @discardableResult
    static func register() async -> Error? {
        let domain = NSFileProviderDomain(
            identifier: identifier,
            displayName: String(localized: "Regi Clipboard")
        )
        do {
            let existing = try await NSFileProviderManager.domains()
            log.info("[FP] \(existing.count, privacy: .public) existing domain(s): \(existing.map(\.identifier.rawValue).joined(separator: ", "), privacy: .public)")
            if let stale = existing.first(where: { $0.identifier == identifier }) {
                // A domain outlives the process that made it, so a
                // reinstall or a crash leaves one behind pointing at an
                // extension build that no longer exists.
                try await NSFileProviderManager.remove(stale)
                log.info("[FP] removed stale domain")
            }
            try await NSFileProviderManager.add(domain)
            log.info("[FP] domain registered OK: \(identifier.rawValue, privacy: .public)")
            if let manager = NSFileProviderManager(for: domain) {
                let root = try await manager.getUserVisibleURL(for: .rootContainer)
                log.info("[FP] user-visible root: \(root.path, privacy: .public)")
            }
            return nil
        } catch {
            log.error("[FP] domain registration FAILED: \(String(describing: error), privacy: .public)")
            return error
        }
    }

    static func unregister() async {
        let domain = NSFileProviderDomain(identifier: identifier, displayName: "Regi Clipboard")
        do {
            try await NSFileProviderManager.remove(domain)
            log.info("[FP] domain removed")
        } catch {
            log.error("[FP] domain removal failed: \(String(describing: error), privacy: .public)")
        }
    }
}
