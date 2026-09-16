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
@MainActor
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
            await connectToExtension()
            startKeepAlive()
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

    // MARK: - Connection to the extension

    /// Kept for the process's lifetime: the extension calls back along it
    /// whenever something reads one of our files.
    private static var connection: NSXPCConnection?
    private static let host = ClipboardFileHost()
    /// Guards against two reconnect attempts racing after an extension
    /// restart, which drops both the interruption and the invalidation
    /// handler on us at once.
    private static var isReconnecting = false
    private static var keepAlive: Task<Void, Never>?

    /// How often to check the extension is still reachable while we have
    /// files on offer.
    private static let keepAliveInterval = Duration.seconds(5)

    /// Open (or re-open) the channel the extension uses to reach us.
    ///
    /// The app is the side that connects, but the traffic runs the other
    /// way: we export `ClipboardFileHost` and the extension calls it. That
    /// is simply how `NSFileProviderService` is shaped — only the app can
    /// initiate.
    static func connectToExtension() async {
        let domain = NSFileProviderDomain(identifier: identifier, displayName: "Regi Clipboard")
        guard let manager = NSFileProviderManager(for: domain) else {
            log.error("[FP] no manager for domain; cannot connect")
            return
        }
        do {
            let service = try await manager.service(
                named: ClipboardFileProviderIPC.serviceName,
                for: .rootContainer
            )
            guard let service else {
                log.error("[FP] extension vends no '\(ClipboardFileProviderIPC.serviceName.rawValue, privacy: .public)' service")
                return
            }
            let connection = try await service.fileProviderConnection()
            connection.exportedInterface = ClipboardFileProviderIPC.hostInterface()
            connection.exportedObject = host
            // The extension is a short-lived XPC service: the system tears
            // it down when idle and relaunches it on demand. Without
            // reconnecting, the first such cycle would leave the app
            // exporting nothing and every later paste answering "no files".
            connection.interruptionHandler = {
                log.error("[FP] connection to extension interrupted; reconnecting")
                Task { @MainActor in await reconnect() }
            }
            connection.invalidationHandler = {
                log.error("[FP] connection to extension invalidated; reconnecting")
                Task { @MainActor in await reconnect() }
            }
            connection.remoteObjectInterface = ClipboardFileProviderIPC.providerInterface()
            connection.resume()
            self.connection = connection
            // Nothing is actually connected until a message crosses, and
            // every other call here runs the other way. Without this the
            // extension never sees the connection at all.
            let established = await withCheckedContinuation { continuation in
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    log.error("[FP] handshake failed: \(String(describing: error), privacy: .public)")
                    continuation.resume(returning: false)
                } as? ClipboardFileProviderPinging
                guard let proxy else { return continuation.resume(returning: false) }
                proxy.ping { connected in continuation.resume(returning: connected) }
            }
            log.info("[FP] connected to extension (handshake \(established ? "ok" : "failed", privacy: .public))")
        } catch {
            log.error("[FP] connecting to extension failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Make sure the extension can reach us, connecting if it cannot.
    ///
    /// Necessary because the system creates and destroys extension
    /// instances as it pleases, and a fresh instance starts with no
    /// connection. Nothing tells the app that happened — the extension
    /// cannot call us to say so, which is the whole problem — so the app
    /// has to check. Without this, a paste minutes after the copy reaches
    /// an extension that has been recycled in the meantime and answers
    /// "Regi is not running".
    @discardableResult
    static func ensureConnected() async -> Bool {
        if await pingSucceeds() { return true }
        await reconnect()
        return await pingSucceeds()
    }

    private static func pingSucceeds() async -> Bool {
        guard let connection else { return false }
        return await withCheckedContinuation { continuation in
            var resumed = false
            let finish: (Bool) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                finish(false)
            } as? ClipboardFileProviderPinging
            guard let proxy else { return finish(false) }
            // The reply says whether the extension can reach *us*, not just
            // that its listener answered. Those are different things: the
            // system recycles extension instances inside a live process, and
            // a stale listener will happily answer for one that has no
            // connection left.
            proxy.ping { connected in finish(connected) }
        }
    }

    /// Keep the channel up for as long as there is something to serve. A
    /// paste can come minutes after the copy, and it has to find us.
    private static func startKeepAlive() {
        guard keepAlive == nil else { return }
        keepAlive = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: keepAliveInterval)
                guard !ClipboardFilePromiseRegistry.shared.manifest.isEmpty else { continue }
                if !(await pingSucceeds()) {
                    log.info("[FP] keepalive: extension unreachable; reconnecting")
                    await reconnect()
                }
            }
        }
    }

    /// Re-open the channel after the extension has been torn down and
    /// relaunched. Deliberately unhurried — there is nothing to serve until
    /// something asks, and hammering a failing connect helps no one.
    private static func reconnect() async {
        guard !isReconnecting else { return }
        isReconnecting = true
        defer { isReconnecting = false }
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection = nil
        try? await Task.sleep(for: .seconds(1))
        await connectToExtension()
    }

    /// Drop the connection without tearing down the domain.
    static func disconnect() {
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
    }

    /// Tell the system the offered set has changed, so Finder re-reads it.
    static func signalChange() async {
        let domain = NSFileProviderDomain(identifier: identifier, displayName: "Regi Clipboard")
        guard let manager = NSFileProviderManager(for: domain) else { return }
        do {
            try await manager.signalEnumerator(for: .rootContainer)
            try await manager.signalEnumerator(for: .workingSet)
        } catch {
            log.error("[FP] signalEnumerator failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Cached because it never changes for the life of the domain, and
    /// the pasteboard write must not wait on an XPC round trip.
    private static var cachedRoot: URL?

    /// Where the domain is mounted in the user's file system.
    static func rootURL() async -> URL? {
        if let cachedRoot { return cachedRoot }
        let domain = NSFileProviderDomain(identifier: identifier, displayName: "Regi Clipboard")
        guard let manager = NSFileProviderManager(for: domain) else { return nil }
        cachedRoot = try? await manager.getUserVisibleURL(for: .rootContainer)
        return cachedRoot
    }

    /// Take the domain away entirely. Called on quit: with Regi gone the
    /// files cannot be fetched, and a domain left in the Finder sidebar
    /// serving nothing but errors is worse than no domain at all.
    static func teardown() async {
        keepAlive?.cancel()
        keepAlive = nil
        disconnect()
        await unregister()
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
