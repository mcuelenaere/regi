import FileProvider
import Foundation
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: "app.regi.mac", category: "fileprovider")

/// Replicated File Provider serving the files the host clipboard has
/// offered, materialising each one only when something actually reads it.
///
/// This exists because promising through the pasteboard does not work. A
/// lazily-provided `public.file-url` is force-resolved by Universal
/// Clipboard about 100ms after every clipboard change so the clipboard
/// can mirror to the user's other devices (`pboard` logs it under
/// `CFPasteboard:remote`), and a data provider is asked exactly once with
/// no second chance. So "lazy" there always meant transferring, whether
/// or not anyone pasted — on a 300 MB file, a full pull nobody asked for.
///
/// Here the laziness is real and measured: publishing an item's URL on
/// the pasteboard leaves it at 0 bytes on disk and never calls
/// `fetchContents`; reading the file does.
///
/// The bytes come from `ClipboardBridge`, which lives in Regi, not here —
/// see `ClipboardFileHosting`.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderServicing {

    private let domain: NSFileProviderDomain
    /// Process-wide, not per-instance. The system tears this class down
    /// and builds a new one inside the *same* process whenever it feels
    /// like it; a per-instance connection meant the replacement started
    /// with none while the old one's listener carried on answering the
    /// app's keepalive, so Regi believed it was connected and every
    /// request answered "Regi is not running".
    private let host = HostConnection.shared

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        log.info("[FP] extension init for domain \(domain.identifier.rawValue, privacy: .public)")
    }

    func invalidate() {
        // Only this instance is going away; the process, its listener and
        // its connection to Regi outlive it. Tearing the connection down
        // here would break the instance that replaces us.
        log.info("[FP] invalidate (instance only; connection kept)")
    }

    // MARK: - Items

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        if identifier == .rootContainer {
            completionHandler(RootItem(), nil)
            return Progress()
        }
        host.manifest { manifest in
            if !manifest.isEmpty, identifier.rawValue == manifest.folderIdentifier {
                completionHandler(OfferFolderItem(manifest), nil)
                return
            }
            guard let descriptor = manifest.files.first(where: { $0.identifier == identifier.rawValue }) else {
                // Either Regi is gone or the offer was superseded; both mean
                // this item no longer exists.
                completionHandler(nil, NSFileProviderError(.noSuchItem))
                return
            }
            completionHandler(ClipboardFileItem(descriptor, parent: manifest.folderIdentifier), nil)
        }
        return Progress()
    }

    /// The hook the whole design exists for.
    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        log.info("[FP] fetchContents for \(itemIdentifier.rawValue, privacy: .public)")
        let progress = Progress(totalUnitCount: 1)

        host.manifest { [weak self] manifest in
            guard let self else {
                completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                return
            }
            guard let descriptor = manifest.files.first(where: { $0.identifier == itemIdentifier.rawValue }) else {
                log.error("[FP] fetchContents: \(itemIdentifier.rawValue, privacy: .public) is not on offer any more")
                completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                return
            }
            self.host.fetchFile(identifier: descriptor.identifier) { handle, failure in
                guard let handle else {
                    log.error("[FP] fetchContents: pull failed: \(failure ?? "no host", privacy: .public)")
                    completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
                    return
                }
                do {
                    let staged = try self.stage(handle, named: descriptor.filename)
                    progress.completedUnitCount = 1
                    log.info("[FP] fetchContents: materialised '\(descriptor.filename, privacy: .public)'")
                    completionHandler(staged, ClipboardFileItem(descriptor, parent: manifest.folderIdentifier), nil)
                } catch {
                    log.error("[FP] fetchContents: staging failed: \(String(describing: error), privacy: .public)")
                    completionHandler(nil, nil, error)
                }
            }
        }
        return progress
    }

    /// Copy the bytes out of the descriptor Regi handed us and into a file
    /// the system can take ownership of. Chunked, so a multi-gigabyte
    /// paste costs a buffer rather than its own size in memory.
    private func stage(_ handle: FileHandle, named filename: String) throws -> URL {
        // Must live in the domain's own temporary directory: the system
        // takes ownership of what we hand back, and will not accept a file
        // from anywhere else.
        guard let manager = NSFileProviderManager(for: domain) else {
            throw NSFileProviderError(.providerNotFound)
        }
        let directory = try manager.temporaryDirectoryURL()
        let staged = directory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
        guard FileManager.default.createFile(atPath: staged.path, contents: nil) else {
            throw NSFileProviderError(.cannotSynchronize)
        }
        let out = try FileHandle(forWritingTo: staged)
        defer { try? out.close(); try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try out.write(contentsOf: chunk)
        }
        return staged
    }

    // MARK: - Read-only domain

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        // The domain mirrors the host's clipboard; nothing here is ours to
        // change, and a writable domain would invite Finder to try.
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        completionHandler(nil)
        return Progress()
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        log.info("[FP] enumerator(for: \(containerItemIdentifier.rawValue, privacy: .public))")
        return ClipboardEnumerator(host: host, container: containerItemIdentifier)
    }
}

// MARK: - Connection back to Regi

/// Holds the XPC connection Regi opens to this extension, and calls back
/// along it. Every reply is delivered on an XPC queue.
private final class HostConnection: @unchecked Sendable {
    static let shared = HostConnection()

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    /// Whether Regi is reachable right now. Reported back over the ping so
    /// the app can tell a live connection from a live *listener* attached
    /// to nothing.
    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return connection != nil
    }

    func adopt(_ connection: NSXPCConnection) {
        lock.lock(); defer { lock.unlock() }
        self.connection = connection
        log.info("[FP] adopted connection from Regi")
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        connection = nil
    }

    /// A proxy whose error handler is wired to `onFailure`, so a dead peer
    /// produces an answer instead of silence. Returning a proxy whose
    /// error handler merely logged meant `fetchContents` never called its
    /// completion — the system then waited for a reply that was never
    /// coming, which is what hung Finder and `cp` for thirty seconds.
    private func proxy(onFailure: @escaping (String) -> Void) -> ClipboardFileHosting? {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard let connection else { return nil }
        return connection.remoteObjectProxyWithErrorHandler { error in
            log.error("[FP] host proxy error: \(String(describing: error), privacy: .public)")
            onFailure(String(describing: error))
        } as? ClipboardFileHosting
    }

    /// Wait briefly for Regi to (re)connect.
    ///
    /// The system reaps this process when it is idle and launches a fresh
    /// one the moment something reads a file, so a fetch routinely arrives
    /// before the app has dialled back in. Failing immediately turned that
    /// ordinary race into "the file does not exist".
    private func awaitConnection(timeout: TimeInterval, _ completion: @escaping (Bool) -> Void) {
        if isConnected { return completion(true) }
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if isConnected { return completion(true) }
            guard Date() < deadline else {
                log.error("[FP] waited \(timeout, privacy: .public)s for Regi and it never connected")
                return completion(false)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
    }

    /// Empty when Regi isn't running — which is the honest answer, since a
    /// promise is only redeemable while its offer is the live clipboard.
    func manifest(_ completion: @escaping (ClipboardFileManifest) -> Void) {
        var answered = false
        let finish: (ClipboardFileManifest) -> Void = { value in
            guard !answered else { return }
            answered = true
            completion(value)
        }
        awaitConnection(timeout: Self.connectWait) { [weak self] connected in
            guard connected, let self,
                  let proxy = self.proxy(onFailure: { _ in finish(.empty) })
            else {
                log.error("[FP] manifest: no connection to Regi")
                return finish(.empty)
            }
            proxy.listPromisedFiles { data in
                guard let data,
                      let decoded = try? JSONDecoder().decode(ClipboardFileManifest.self, from: data)
                else {
                    log.error("[FP] manifest: no/undecodable reply")
                    return finish(.empty)
                }
                log.debug("[FP] manifest → \(decoded.files.count, privacy: .public) in '\(decoded.folderName, privacy: .public)'")
                finish(decoded)
            }
        }
    }

    func fetchFile(identifier: String, completion: @escaping (FileHandle?, String?) -> Void) {
        var answered = false
        let finish: (FileHandle?, String?) -> Void = { handle, failure in
            guard !answered else { return }
            answered = true
            completion(handle, failure)
        }
        awaitConnection(timeout: Self.connectWait) { [weak self] connected in
            guard connected, let self,
                  let proxy = self.proxy(onFailure: { finish(nil, $0) })
            else {
                return finish(nil, "Regi is not reachable")
            }
            proxy.fetchPromisedFile(identifier: identifier) { handle, failure in
                finish(handle, failure)
            }
        }
    }

    /// How long a fetch will wait for the app to come back. Generous
    /// enough to cover the app's reconnect, short enough that a paste with
    /// Regi genuinely gone fails rather than hangs.
    private static let connectWait: TimeInterval = 8
}

/// Vends the endpoint Regi connects to. The system hands this to the app
/// when it asks for our service by name.
final class ClipboardFileServiceSource: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate {
    /// One listener for the process, for the same reason the connection is
    /// process-wide: extension instances come and go beneath it.
    static let shared = ClipboardFileServiceSource()

    private let listener = NSXPCListener.anonymous()

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    var serviceName: NSFileProviderServiceName { ClipboardFileProviderIPC.serviceName }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        log.info("[FP] makeListenerEndpoint")
        return listener.endpoint
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        log.info("[FP] shouldAcceptNewConnection")
        // Regi exports the host object, which is what we actually call.
        connection.remoteObjectInterface = ClipboardFileProviderIPC.hostInterface()
        // And we export a ping, purely so Regi has something to send that
        // establishes the connection in the first place.
        connection.exportedInterface = ClipboardFileProviderIPC.providerInterface()
        connection.exportedObject = PingResponder()
        HostConnection.shared.adopt(connection)
        connection.resume()
        return true
    }
}

private final class PingResponder: NSObject, ClipboardFileProviderPinging {
    func ping(reply: @escaping (Bool) -> Void) {
        // Answer with whether the *serving* side can actually reach Regi,
        // not merely that this listener is up. Those came apart once
        // already, and the app could not tell.
        let connected = HostConnection.shared.isConnected
        if !connected { log.error("[FP] ping: listener is up but no connection to Regi") }
        reply(connected)
    }
}

extension FileProviderExtension {
    /// `NSFileProviderServicing`. Declared on the class rather than bolted
    /// on in an extension — the system checks protocol conformance, and
    /// an unadvertised method is simply never found.
    func supportedServiceSources(
        for itemIdentifier: NSFileProviderItemIdentifier,
        completionHandler: @escaping ([NSFileProviderServiceSource]?, Error?) -> Void
    ) -> Progress {
        log.info("[FP] supportedServiceSources asked for \(itemIdentifier.rawValue, privacy: .public)")
        completionHandler([ClipboardFileServiceSource.shared], nil)
        return Progress()
    }
}

// MARK: - Items

private final class RootItem: NSObject, NSFileProviderItem {
    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { "Regi Clipboard" }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating] }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data("1".utf8), metadataVersion: Data("1".utf8))
    }
}

/// The folder one offer's files live in.
///
/// Files sit inside it rather than loose in the domain root so that two
/// offers carrying the same name cannot collide — a superseded offer's
/// items are deleted asynchronously, so the two can briefly coexist —
/// and so the offer id stays out of the file's own name, which is what
/// the user sees once they paste.
private final class OfferFolderItem: NSObject, NSFileProviderItem {
    private let manifest: ClipboardFileManifest

    init(_ manifest: ClipboardFileManifest) {
        self.manifest = manifest
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier { .init(manifest.folderIdentifier) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { manifest.folderName }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating] }
    var itemVersion: NSFileProviderItemVersion {
        // Folded over the contents, so replacing an offer's files under an
        // unchanged folder still reads as a change.
        let stamp = Data((manifest.folderIdentifier + "|" + manifest.files.map(\.identifier).joined(separator: ",")).utf8)
        return NSFileProviderItemVersion(contentVersion: stamp, metadataVersion: stamp)
    }
}

/// One file the host clipboard is offering. Read-only, and dataless until
/// something opens it.
private final class ClipboardFileItem: NSObject, NSFileProviderItem {
    private let descriptor: ClipboardFileDescriptor
    private let parent: String

    init(_ descriptor: ClipboardFileDescriptor, parent: String) {
        self.descriptor = descriptor
        self.parent = parent
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier { .init(descriptor.identifier) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .init(parent) }
    var filename: String { descriptor.filename }
    var documentSize: NSNumber? { NSNumber(value: descriptor.size) }
    var contentType: UTType {
        let ext = (descriptor.filename as NSString).pathExtension
        return (ext.isEmpty ? nil : UTType(filenameExtension: ext)) ?? .data
    }
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading] }
    var itemVersion: NSFileProviderItemVersion {
        // The identifier already carries the offer id, so an item's content
        // never changes under a fixed identifier.
        NSFileProviderItemVersion(
            contentVersion: Data(descriptor.identifier.utf8),
            metadataVersion: Data(descriptor.identifier.utf8)
        )
    }
}

// MARK: - Enumeration

private final class ClipboardEnumerator: NSObject, NSFileProviderEnumerator {
    private let host: HostConnection
    private let container: NSFileProviderItemIdentifier
    /// What we last told the system about, so a superseded offer's items
    /// can be reported as deleted rather than lingering in Finder.
    private var lastReported: Set<String> = []
    private let lock = NSLock()

    init(host: HostConnection, container: NSFileProviderItemIdentifier) {
        self.host = host
        self.container = container
        super.init()
    }

    func invalidate() {}

    /// What this container holds right now.
    private func contents(of manifest: ClipboardFileManifest) -> [NSFileProviderItem] {
        if manifest.isEmpty { return [] }
        if container == .rootContainer { return [OfferFolderItem(manifest)] }
        guard container.rawValue == manifest.folderIdentifier else { return [] }
        return manifest.files.map { ClipboardFileItem($0, parent: manifest.folderIdentifier) }
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        log.debug("[FP] enumerateItems container=\(self.container.rawValue, privacy: .public)")
        host.manifest { [weak self] manifest in
            guard let self else { return observer.finishEnumerating(upTo: nil) }
            let items = self.contents(of: manifest)
            self.remember(items)
            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: nil)
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        log.debug("[FP] enumerateChanges container=\(self.container.rawValue, privacy: .public)")
        host.manifest { [weak self] manifest in
            guard let self else {
                return observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            }
            // The working set is asked about everything, not one container,
            // so report the whole offer there.
            let items = self.container == .workingSet
                ? Self.everything(in: manifest)
                : self.contents(of: manifest)
            let current = Set(items.map(\.itemIdentifier.rawValue))
            let gone = self.remember(items).subtracting(current)
            if !gone.isEmpty {
                log.debug("[FP] enumerateChanges: \(gone.count, privacy: .public) item(s) gone")
                observer.didDeleteItems(withIdentifiers: gone.map { NSFileProviderItemIdentifier($0) })
            }
            observer.didUpdate(items)
            observer.finishEnumeratingChanges(upTo: Self.anchor(for: manifest), moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        host.manifest { completionHandler(Self.anchor(for: $0)) }
    }

    private static func everything(in manifest: ClipboardFileManifest) -> [NSFileProviderItem] {
        guard !manifest.isEmpty else { return [] }
        return [OfferFolderItem(manifest)]
            + manifest.files.map { ClipboardFileItem($0, parent: manifest.folderIdentifier) }
    }

    /// Anchor derived from the offered set, so the system re-enumerates
    /// exactly when the host clipboard has moved on.
    private static func anchor(for manifest: ClipboardFileManifest) -> NSFileProviderSyncAnchor {
        let stamp = manifest.folderIdentifier + "|" + manifest.files.map(\.identifier).joined(separator: ",")
        return NSFileProviderSyncAnchor(Data(stamp.utf8))
    }

    @discardableResult
    private func remember(_ items: [NSFileProviderItem]) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let previous = lastReported
        lastReported = Set(items.map(\.itemIdentifier.rawValue))
        return previous
    }
}
