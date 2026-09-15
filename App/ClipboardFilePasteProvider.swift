import AppKit
import Foundation
import KVMKit
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: "app.regi.mac", category: "clipboard-promise")

/// Publishes one inbound clipboard file as a pasteboard item whose
/// `public.file-url` is *promised* rather than present: the bytes are
/// pulled over the bridge only if something actually pastes.
///
/// Why this and not `NSFilePromiseProvider`, which reads like the
/// obvious fit: that class only works for drag-and-drop. Written to a
/// pasteboard it advertises its metadata but its fulfilment channel is
/// drag-session-scoped — `promised-file-name` comes back empty,
/// `writePromiseToURL` is never called, and Finder simply cannot paste
/// it. Measured here, and long-standing: rdar-era Apple Developer Forum
/// threads report the identical symptoms with no answer.
///
/// `NSPasteboardItemDataProvider` is the older, general mechanism and
/// the one that works. Declaring `public.file-url` up front also gets
/// `NSFilenamesPboardType` derived for free, which is what Finder
/// actually reads on paste, and the owner is asked for data only when a
/// paste happens.
///
/// The awkward part is that AppKit demands the data **synchronously**:
/// there is no async escape hatch in the callback. Since the pull needs
/// the `@MainActor` bridge — and the `StreamData` frames we are waiting
/// for are delivered on this very thread — blocking outright would
/// deadlock against our own transfer. So we spin a nested run loop,
/// which keeps the main queue (and with it the bridge) serviced.
@MainActor
final class ClipboardFilePasteProvider: NSObject, NSPasteboardItemDataProvider {

    /// Pulls the bytes, returning where they landed locally.
    typealias Redeem = @MainActor (ClipboardFilePromise) async throws -> URL

    private let promise: ClipboardFilePromise
    private let redeem: Redeem

    private init(promise: ClipboardFilePromise, redeem: @escaping Redeem) {
        self.promise = promise
        self.redeem = redeem
        super.init()
    }

    /// One pasteboard item standing for `promise`.
    ///
    /// The item retains its data provider, so the promise stays
    /// redeemable for as long as the item is on the pasteboard — outliving
    /// the session window if need be, where it fails cleanly rather than
    /// dangling.
    static func makeItem(
        for promise: ClipboardFilePromise,
        redeem: @escaping Redeem
    ) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setDataProvider(
            ClipboardFilePasteProvider(promise: promise, redeem: redeem),
            forTypes: [.fileURL]
        )
        return item
    }

    // MARK: - NSPasteboardItemDataProvider

    /// AppKit declares this without isolation, but documents — and we
    /// measured — that it arrives on the main thread. `assumeIsolated`
    /// makes the main-actor work below sound rather than merely likely,
    /// and traps loudly if that ever stops being true instead of racing
    /// quietly.
    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        MainActor.assumeIsolated {
            provideFileURL(into: item, type: type)
        }
    }

    private func provideFileURL(into item: NSPasteboardItem, type: NSPasteboard.PasteboardType) {
        let started = Date()
        log.info("[PROMISE] '\(self.promise.fileName, privacy: .public)' asked for \(type.rawValue, privacy: .public); pulling")

        var outcome: Result<URL, Error>?
        let promise = self.promise
        Task { @MainActor [redeem] in
            do { outcome = .success(try await redeem(promise)) }
            catch { outcome = .failure(error) }
        }

        // Nested run loop rather than a semaphore: the work we are
        // waiting on is main-actor isolated, so the main queue has to
        // keep draining or nothing can finish.
        let deadline = started.addingTimeInterval(Self.timeout(forSize: promise.size))
        while outcome == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        let elapsed = Date().timeIntervalSince(started)
        switch outcome {
        case .success(let url):
            // Supplying the staged URL makes this an ordinary file paste:
            // the receiving app copies out of our cache directory.
            item.setData(url.dataRepresentation, forType: type)
            log.info("[PROMISE] '\(self.promise.fileName, privacy: .public)' supplied \(url.lastPathComponent, privacy: .public) after \(elapsed, privacy: .public)s")
        case .failure(let error):
            // Leaving the type unset is the only way to say "nothing" —
            // the paste yields no file rather than a broken one.
            log.error("[PROMISE] '\(self.promise.fileName, privacy: .public)' could not be redeemed after \(elapsed, privacy: .public)s: \(String(describing: error), privacy: .public)")
        case nil:
            log.error("[PROMISE] '\(self.promise.fileName, privacy: .public)' timed out after \(elapsed, privacy: .public)s; supplying nothing")
        }
    }

    // MARK: - Internal

    /// How long to hold the paste open. The pasteboard gives us no
    /// progress channel — the receiving app is simply blocked until we
    /// answer — so all we can do is bound the total, generously enough
    /// that a large file on a slow link still lands. Floor covers the
    /// round trip; the rest assumes a pessimistic 128 KiB/s.
    static func timeout(forSize size: UInt64) -> TimeInterval {
        let slowRate: Double = 128 * 1024
        return min(30 + Double(size) / slowRate, 10 * 60)
    }
}
