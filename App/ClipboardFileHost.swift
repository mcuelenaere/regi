import Foundation
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "fileprovider")

/// Regi's side of the connection to its File Provider extension.
///
/// Every method here is called from the extension's process, off the main
/// thread, so each hops onto the main actor where the registry and the
/// bridge live.
final class ClipboardFileHost: NSObject, ClipboardFileHosting, @unchecked Sendable {

    func listPromisedFiles(reply: @escaping (Data?) -> Void) {
        Task { @MainActor in
            let descriptors = ClipboardFilePromiseRegistry.shared.descriptors
            log.debug("[FP] host: listPromisedFiles → \(descriptors.count, privacy: .public)")
            reply(try? JSONEncoder().encode(descriptors))
        }
    }

    func fetchPromisedFile(identifier: String, reply: @escaping (FileHandle?, String?) -> Void) {
        Task { @MainActor in
            log.info("[FP] host: fetchPromisedFile '\(identifier, privacy: .public)' — pulling over the bridge")
            do {
                let url = try await ClipboardFilePromiseRegistry.shared.fetch(identifier: identifier)
                // A descriptor, not a path: the extension is sandboxed and
                // could not open our cache directory by name.
                let handle = try FileHandle(forReadingFrom: url)
                log.info("[FP] host: '\(identifier, privacy: .public)' ready at \(url.lastPathComponent, privacy: .public)")
                reply(handle, nil)
            } catch {
                log.error("[FP] host: '\(identifier, privacy: .public)' failed: \(String(describing: error), privacy: .public)")
                reply(nil, String(describing: error))
            }
        }
    }
}
