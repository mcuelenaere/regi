import AppKit
import Foundation
import KVMKit
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: "app.regi.mac", category: "clipboard-promise")

/// What one `NSFilePromiseProvider` on the pasteboard stands for.
///
/// Lives in the provider's `userInfo`, which is also where the delegate
/// is kept alive: `NSFilePromiseProvider.delegate` is an unowned
/// reference, and the pasteboard routinely outlives the session window
/// whose manager created it. Holding the delegate here ties its lifetime
/// to the provider's — nothing dangles when the user closes the window
/// and pastes afterwards.
final class ClipboardFilePromiseContext: NSObject {
    let promise: ClipboardFilePromise
    let provider: ClipboardFilePromiseProvider

    init(promise: ClipboardFilePromise, provider: ClipboardFilePromiseProvider) {
        self.promise = promise
        self.provider = provider
    }
}

/// `NSFilePromiseProviderDelegate` that redeems a `ClipboardFilePromise`
/// against the session's `ClipboardBridge` when — and only when — the
/// receiving app actually asks for the file.
///
/// This is the whole point of promising rather than downloading: a
/// 12 MB file takes seconds to pull, and the local pasteboard must not
/// hold the *previous* clipboard's contents for that long. The offer
/// lands, the pasteboard updates immediately, and Finder shows its own
/// copy progress if the user ever pastes.
///
/// AppKit calls `filePromiseProvider(_:writePromiseTo:completionHandler:)`
/// on `operationQueue(for:)`, off the main thread, while the bridge is
/// `@MainActor` — hence the hop, and hence `@unchecked Sendable` (the
/// only mutable state is behind that hop).
final class ClipboardFilePromiseProvider: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {

    /// Pulls the bytes. Returns where they landed locally; throws when
    /// the offer has been superseded or the transfer failed.
    private let redeem: @Sendable (ClipboardFilePromise) async throws -> URL

    /// AppKit fulfils promises here. Serial: two destinations asking for
    /// the same file would otherwise both block a queue thread for the
    /// whole transfer, and the bridge already dedupes the pull itself.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.regi.mac.clipboard-file-promise"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(redeem: @escaping @Sendable (ClipboardFilePromise) async throws -> URL) {
        self.redeem = redeem
    }

    /// One pasteboard item promising `promise`'s file.
    func makeProvider(for promise: ClipboardFilePromise) -> NSFilePromiseProvider {
        let provider = NSFilePromiseProvider(
            fileType: Self.fileType(for: promise.fileName, mime: promise.mime),
            delegate: self
        )
        provider.userInfo = ClipboardFilePromiseContext(promise: promise, provider: self)
        return provider
    }

    // MARK: - NSFilePromiseProviderDelegate

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        context(filePromiseProvider)?.promise.fileName ?? "file"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let promise = context(filePromiseProvider)?.promise else {
            log.error("[PROMISE] fulfilment asked for a provider with no context")
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        let redeem = self.redeem
        // Detached rather than inherited: this runs on AppKit's promise
        // queue, and the copy below must not end up back on the main
        // actor behind the `await`.
        Task.detached(priority: .userInitiated) {
            let started = Date()
            do {
                let source = try await redeem(promise)
                try Self.place(source, at: url)
                log.info("[PROMISE] '\(promise.fileName, privacy: .public)' fulfilled into \(url.lastPathComponent, privacy: .public) in \(Date().timeIntervalSince(started), privacy: .public)s")
                completionHandler(nil)
            } catch {
                log.error("[PROMISE] '\(promise.fileName, privacy: .public)' could not be fulfilled: \(String(describing: error), privacy: .public)")
                completionHandler(error)
            }
        }
    }

    // MARK: - Internal

    private func context(_ provider: NSFilePromiseProvider) -> ClipboardFilePromiseContext? {
        provider.userInfo as? ClipboardFilePromiseContext
    }

    /// Put the pulled file where AppKit asked for it.
    ///
    /// A copy, not a move: the same promise can be fulfilled more than
    /// once (two destinations, or a paste followed by another paste), and
    /// the bridge hands back the same cached URL each time.
    private static func place(_ source: URL, at destination: URL) throws {
        let fm = FileManager.default
        // AppKit hands us a fresh name in its own staging directory, but
        // a retried fulfilment can find its own leftovers there.
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    /// UTI for the promise, so the receiving app knows what it's being
    /// offered before any bytes move. The extension is the better signal:
    /// the peer's MIME is guessed from that same extension, and a file
    /// whose extension we don't know is still perfectly copyable.
    static func fileType(for fileName: String, mime: String) -> String {
        let ext = (fileName as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type.identifier
        }
        if let type = UTType(mimeType: mime) {
            return type.identifier
        }
        return UTType.data.identifier
    }
}
