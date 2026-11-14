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
    /// The sync manager whose bridge can redeem the current files. Each
    /// KVM window has its own, and only that one may withdraw them.
    private var owner: ObjectIdentifier?
    /// Bumped per offer. The peer's clipboard ids restart at 1 on every
    /// connection and repeat across hosts, so on their own they would
    /// hand a new file an identifier — and a path — the system already
    /// has materialised bytes for.
    private var generation = 0

    /// Replace the current offer's files. Called on every inbound offer,
    /// including ones carrying no files at all — that still clears the
    /// previous offer's, which is the point.
    ///
    /// Returns where each file appears relative to the domain root, and
    /// whether the offered set actually changed — a text-only offer
    /// following another text-only offer changes nothing, and must not
    /// pay for an XPC round trip.
    func publish(
        _ promises: [ClipboardFilePromise],
        owner: ObjectIdentifier,
        redeem: @escaping Redeem
    ) -> (paths: [String], changed: Bool) {
        guard !promises.isEmpty else { return ([], clear()) }
        generation += 1
        // One offer may carry two files of the same name, copied from
        // different directories. On disk `O_EXCL` sorts that out; here the
        // names are only ever presented, so nothing would.
        let names = ClipboardFileRules.disambiguated(fileNames: promises.map(\.fileName))
        let incoming = zip(promises, names).map { promise, name in
            (identifier: "\(generation)-\(promise.index)", filename: name, size: promise.size)
        }
        self.promises = Dictionary(uniqueKeysWithValues: zip(incoming.map(\.identifier), promises).map { ($0, $1) })
        self.entries = incoming
        folderName = "\(generation)"
        folderIdentifier = "offer-\(generation)"
        self.redeem = redeem
        self.owner = owner
        log.info("[FP] registry now offering \(promises.count, privacy: .public) file(s) in '\(self.folderName, privacy: .public)': \(names.joined(separator: ", "), privacy: .public)")
        return (names.map { "\(folderName)/\($0)" }, true)
    }

    /// Withdraw the files if `owner` is the one offering them. Returns
    /// whether anything was withdrawn.
    @discardableResult
    func withdraw(owner: ObjectIdentifier) -> Bool {
        guard self.owner == owner else { return false }
        return clear()
    }

    @discardableResult
    private func clear() -> Bool {
        guard !entries.isEmpty else { return false }
        log.info("[FP] registry cleared")
        promises.removeAll()
        entries.removeAll()
        folderName = ""
        folderIdentifier = ""
        redeem = nil
        owner = nil
        return true
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

    /// Pull one file. Throws if the identifier belongs to an offer that
    /// has since been superseded.
    func fetch(identifier: String) async throws -> URL {
        guard let promise = promises[identifier], let redeem else {
            throw ClipboardPromiseError.superseded
        }
        return try await redeem(promise)
    }
}
