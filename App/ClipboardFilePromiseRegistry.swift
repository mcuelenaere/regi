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
    private var order: [String] = []
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
    /// Returns whether the offered set actually changed — a text-only
    /// offer following another text-only offer changes nothing, and must
    /// not pay for an XPC round trip before the pasteboard is written.
    @discardableResult
    func publish(_ promises: [ClipboardFilePromise], redeem: @escaping Redeem) -> Bool {
        let incoming = promises.map(Self.identifier(for:))
        let changed = incoming != order
        self.promises = Dictionary(
            uniqueKeysWithValues: promises.map { (Self.identifier(for: $0), $0) }
        )
        self.order = incoming
        self.redeem = redeem
        if changed {
            log.info("[FP] registry now offering \(promises.count, privacy: .public) file(s): \(promises.map(\.fileName).joined(separator: ", "), privacy: .public)")
        }
        return changed
    }

    func clear() {
        guard !order.isEmpty else { return }
        log.info("[FP] registry cleared")
        promises.removeAll()
        order.removeAll()
        redeem = nil
    }

    var descriptors: [ClipboardFileDescriptor] {
        order.compactMap { id in
            guard let promise = promises[id] else { return nil }
            return ClipboardFileDescriptor(
                identifier: id, filename: promise.fileName, size: promise.size
            )
        }
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
