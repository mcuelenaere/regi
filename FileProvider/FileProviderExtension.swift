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
    private let host = HostConnection()
    /// Held for the extension's lifetime: it owns the anonymous listener
    /// Regi connects to, and a per-call instance would be torn down
    /// before the app ever dialled it.
    private lazy var serviceSource = ClipboardFileServiceSource { [weak self] connection in
        self?.host.adopt(connection)
    }

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        log.info("[FP] extension init for domain \(domain.identifier.rawValue, privacy: .public)")
    }

    func invalidate() {
        log.info("[FP] invalidate")
        host.invalidate()
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
        host.listFiles { descriptors in
            guard let descriptor = descriptors.first(where: { $0.identifier == identifier.rawValue }) else {
                // Either Regi is gone or the offer was superseded; both mean
                // this item no longer exists.
                completionHandler(nil, NSFileProviderError(.noSuchItem))
                return
            }
            completionHandler(ClipboardFileItem(descriptor), nil)
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

        host.listFiles { [weak self] descriptors in
            guard let self else {
                completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                return
            }
            guard let descriptor = descriptors.first(where: { $0.identifier == itemIdentifier.rawValue }) else {
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
                    completionHandler(staged, ClipboardFileItem(descriptor), nil)
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
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    func adopt(_ connection: NSXPCConnection) {
        lock.lock(); defer { lock.unlock() }
        self.connection = connection
        log.info("[FP] adopted connection from Regi")
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        connection = nil
    }

    private var proxyOrNil: ClipboardFileHosting? {
        lock.lock(); defer { lock.unlock() }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            log.error("[FP] host proxy error: \(String(describing: error), privacy: .public)")
        } as? ClipboardFileHosting
    }

    /// Empty when Regi isn't running — which is the honest answer, since a
    /// promise is only redeemable while its offer is the live clipboard.
    func listFiles(_ completion: @escaping ([ClipboardFileDescriptor]) -> Void) {
        guard let proxy = proxyOrNil else {
            log.error("[FP] listFiles: no connection to Regi")
            return completion([])
        }
        proxy.listPromisedFiles { data in
            guard let data, let decoded = try? JSONDecoder().decode([ClipboardFileDescriptor].self, from: data) else {
                log.error("[FP] listFiles: no/undecodable reply")
                return completion([])
            }
            log.info("[FP] listFiles → \(decoded.count, privacy: .public): \(decoded.map(\.filename).joined(separator: ", "), privacy: .public)")
            completion(decoded)
        }
    }

    func fetchFile(identifier: String, completion: @escaping (FileHandle?, String?) -> Void) {
        guard let proxy = proxyOrNil else { return completion(nil, "Regi is not running") }
        proxy.fetchPromisedFile(identifier: identifier, reply: completion)
    }
}

/// Vends the endpoint Regi connects to. The system hands this to the app
/// when it asks for our service by name.
final class ClipboardFileServiceSource: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate {
    private let listener = NSXPCListener.anonymous()
    private let onConnect: (NSXPCConnection) -> Void

    init(onConnect: @escaping (NSXPCConnection) -> Void) {
        self.onConnect = onConnect
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
        onConnect(connection)
        connection.resume()
        return true
    }
}

private final class PingResponder: NSObject, ClipboardFileProviderPinging {
    func ping(reply: @escaping (Bool) -> Void) {
        log.info("[FP] ping from Regi; connection is live")
        reply(true)
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
        completionHandler([serviceSource], nil)
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

/// One file the host clipboard is offering. Read-only, and dataless until
/// something opens it.
private final class ClipboardFileItem: NSObject, NSFileProviderItem {
    private let descriptor: ClipboardFileDescriptor

    init(_ descriptor: ClipboardFileDescriptor) {
        self.descriptor = descriptor
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier { .init(descriptor.identifier) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
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
    /// What we last told the system about, so a superseded offer's files
    /// can be reported as deleted rather than lingering in Finder.
    private var lastReported: Set<String> = []
    private let lock = NSLock()

    init(host: HostConnection, container: NSFileProviderItemIdentifier) {
        self.host = host
        self.container = container
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        log.info("[FP] enumerateItems container=\(self.container.rawValue, privacy: .public)")
        guard container == .rootContainer else {
            observer.finishEnumerating(upTo: nil)
            return
        }
        host.listFiles { [weak self] descriptors in
            self?.remember(descriptors)
            observer.didEnumerate(descriptors.map(ClipboardFileItem.init))
            observer.finishEnumerating(upTo: nil)
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        log.info("[FP] enumerateChanges container=\(self.container.rawValue, privacy: .public)")
        host.listFiles { [weak self] descriptors in
            guard let self else { return }
            let current = Set(descriptors.map(\.identifier))
            let gone = self.remember(descriptors).subtracting(current)
            if !gone.isEmpty {
                observer.didDeleteItems(withIdentifiers: gone.map { NSFileProviderItemIdentifier($0) })
            }
            observer.didUpdate(descriptors.map(ClipboardFileItem.init))
            observer.finishEnumeratingChanges(upTo: Self.anchor(for: current), moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        host.listFiles { descriptors in
            completionHandler(Self.anchor(for: Set(descriptors.map(\.identifier))))
        }
    }

    /// Anchor derived from the offered set, so the system re-enumerates
    /// exactly when the host clipboard has moved on.
    private static func anchor(for identifiers: Set<String>) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(identifiers.sorted().joined(separator: ",").utf8))
    }

    @discardableResult
    private func remember(_ descriptors: [ClipboardFileDescriptor]) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let previous = lastReported
        lastReported = Set(descriptors.map(\.identifier))
        return previous
    }
}
