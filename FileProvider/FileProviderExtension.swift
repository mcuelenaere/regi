import FileProvider
import UniformTypeIdentifiers
import Foundation
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "fileprovider")

/// Minimal replicated File Provider serving the files the host clipboard
/// has offered us.
///
/// The point of the whole exercise: an item is published *dataless*, so
/// the pasteboard can carry a real `file:` URL that costs nothing to
/// resolve. Universal Clipboard resolving that URL reads a path, not
/// 300 MB. Only when something genuinely opens the file does the system
/// call `fetchContents`, and only then do we pull it over the bridge.
///
/// The extension runs in its own process, so it has no access to the
/// `ClipboardBridge` — that lives with the WebRTC session in Regi. The
/// bytes come back over an XPC connection to the app; with no app
/// running there is nothing to serve, which is correct, since a promise
/// is only redeemable while its offer is the host's current clipboard.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    private let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        log.info("[FP] extension init for domain \(domain.identifier.rawValue, privacy: .public)")
    }

    func invalidate() {
        log.info("[FP] invalidate")
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        log.debug("[FP] item(for: \(identifier.rawValue, privacy: .public))")
        if identifier == .rootContainer {
            completionHandler(RootItem(), nil)
        } else if identifier == ProbeItem.identifier {
            completionHandler(ProbeItem(), nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        // This is the hook the entire design exists for: reached only when
        // something genuinely reads the file, never merely by publishing
        // its URL. Whether that holds against Universal Clipboard is
        // exactly what the probe item is here to answer.
        log.info("[FP] fetchContents CALLED for \(itemIdentifier.rawValue, privacy: .public) — on-demand hook fired")
        guard itemIdentifier == ProbeItem.identifier else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("regi-fp-probe-\(UUID().uuidString).bin")
        do {
            try Data(repeating: 0x42, count: Int(ProbeItem.size)).write(to: staged)
            log.info("[FP] fetchContents serving \(ProbeItem.size, privacy: .public) bytes")
            completionHandler(staged, ProbeItem(), nil)
        } catch {
            log.error("[FP] fetchContents failed: \(String(describing: error), privacy: .public)")
            completionHandler(nil, nil, error)
        }
        return Progress()
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
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
        log.debug("[FP] enumerator(for: \(containerItemIdentifier.rawValue, privacy: .public))")
        return RootEnumerator()
    }
}

/// The domain root. Nothing lives under it yet — this scaffold exists to
/// answer whether the extension loads and a domain registers at all.
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

/// A single dataless file, big enough that materialising it would be
/// obvious. Publishing its URL must NOT trigger `fetchContents`; only
/// reading it should.
final class ProbeItem: NSObject, NSFileProviderItem {
    static let identifier = NSFileProviderItemIdentifier("probe-item")
    static let size: Int64 = 300 * 1024 * 1024

    var itemIdentifier: NSFileProviderItemIdentifier { Self.identifier }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { "bigfile.bin" }
    var contentType: UTType { .data }
    var documentSize: NSNumber? { NSNumber(value: Self.size) }
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading] }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data("1".utf8), metadataVersion: Data("1".utf8))
    }
}

private final class RootEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.didEnumerate([ProbeItem()])
        observer.finishEnumerating(upTo: nil)
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("1".utf8)))
    }
}
