import Foundation
import KVMKit
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "fileprovider")

/// The files the host clipboard is currently offering, and how to pull
/// one. Single-slot, mirroring the bridge: a new offer supersedes the
/// previous one wholesale.
///
/// Exists because the File Provider extension runs in another process and
/// asks over XPC, while the promises and the `ClipboardBridge` that
/// redeems them live here. `ClipboardSyncManager` publishes into this;
/// `ClipboardFileHost` reads out of it.
@MainActor
final class ClipboardFilePromiseRegistry {

    static let shared = ClipboardFilePromiseRegistry()

    private init() {}

    /// Redeems a promise against whichever bridge owns it.
    typealias Redeem = @MainActor (ClipboardFilePromise) async throws -> URL

    private var promises: [String: ClipboardFilePromise] = [:]
    /// Offer order, and the name each file shows under.
    private var entries: [(identifier: String, filename: String, size: UInt64)] = []
    private var folderIdentifier = ""
    private var folderName = ""
    private var redeem: Redeem?

    /// The File Provider item identifier for a promise. Carries the
    /// offer id, so an item left over from a superseded offer resolves to
    /// nothing rather than to whatever now sits at that index.
    static func identifier(for promise: ClipboardFilePromise) -> String {
        "\(promise.clipboardId)-\(promise.index)"
    }

    /// Replace the current offer's files. Called on every inbound offer,
    /// including ones carrying no files at all — that still clears the
    /// previous offer's, which is the point.
    ///
    /// Returns whether the offered set actually changed — a text-only
    /// offer following another text-only offer changes nothing, and must
    /// not pay for an XPC round trip before the pasteboard is written.
    @discardableResult
    func publish(_ promises: [ClipboardFilePromise], redeem: @escaping Redeem) -> Bool {
        // One offer may carry two files of the same name, copied from
        // different directories. On disk `O_EXCL` sorts that out; here the
        // names are only ever presented, so nothing would.
        let names = ClipboardFileRules.disambiguated(fileNames: promises.map(\.fileName))
        let incoming = zip(promises, names).map { promise, name in
            (identifier: Self.identifier(for: promise), filename: name, size: promise.size)
        }
        let changed = incoming.map(\.identifier) != entries.map(\.identifier)
            || incoming.map(\.filename) != entries.map(\.filename)

        self.promises = Dictionary(
            uniqueKeysWithValues: promises.map { (Self.identifier(for: $0), $0) }
        )
        self.entries = incoming
        // Everything in one offer shares a clipboard id; an empty offer
        // needs no folder at all.
        if let first = promises.first {
            folderName = "\(first.clipboardId)"
            folderIdentifier = "offer-\(first.clipboardId)"
        } else {
            folderName = ""
            folderIdentifier = ""
        }
        self.redeem = redeem
        if changed {
            log.info("[FP] registry now offering \(promises.count, privacy: .public) file(s) in '\(self.folderName, privacy: .public)': \(names.joined(separator: ", "), privacy: .public)")
        }
        return changed
    }

    func clear() {
        guard !entries.isEmpty else { return }
        log.info("[FP] registry cleared")
        promises.removeAll()
        entries.removeAll()
        folderName = ""
        folderIdentifier = ""
        redeem = nil
    }

    var manifest: ClipboardFileManifest {
        guard !entries.isEmpty else { return .empty }
        return ClipboardFileManifest(
            folderIdentifier: folderIdentifier,
            folderName: folderName,
            files: entries.map {
                ClipboardFileDescriptor(identifier: $0.identifier, filename: $0.filename, size: $0.size)
            }
        )
    }

    /// Where a file we are offering appears, relative to the domain root.
    func relativePath(forIdentifier identifier: String) -> String? {
        guard let entry = entries.first(where: { $0.identifier == identifier }) else { return nil }
        return "\(folderName)/\(entry.filename)"
    }

    /// Pull one file. Throws if the identifier belongs to an offer that
    /// has since been superseded.
    func fetch(identifier: String) async throws -> URL {
        guard let promise = promises[identifier], let redeem else {
            throw ClipboardPromiseError.superseded
        }
        return try await redeem(promise)
    }
}
