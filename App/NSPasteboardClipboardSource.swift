import AppKit
import Foundation
import JetKVMTransport

/// `ClipboardSource` backed by macOS' shared `NSPasteboard.general`.
/// All NSPasteboard methods are documented as thread-safe so the
/// struct trivially satisfies the protocol's `Sendable` requirement.
///
/// MIME mapping mirrors what the host agent expects to receive +
/// what the firmware spec calls out as the Web Clipboard API's
/// accepted set (`text/plain`, `text/html`, `image/png`,
/// `text/uri-list`). Anything else is dropped.
public struct NSPasteboardClipboardSource: ClipboardSource {
    public init() {}

    public func snapshot() async -> ClipboardSnapshot {
        let pb = NSPasteboard.general
        // Capture the changeCount first so a clipboard write that
        // happens partway through the type walk is detected on the
        // very next fetchData call rather than producing a corrupted
        // snapshot.
        let token = ClipboardSnapshotToken(pb.changeCount)
        var descriptors: [ClipboardFormatDescriptor] = []
        guard let types = pb.types else {
            return ClipboardSnapshot(token: token, formats: descriptors)
        }
        for type in types {
            guard let mime = Self.wireMime(for: type) else { continue }
            // NSPasteboard doesn't expose size-without-data; we read
            // here once per snapshot to fill the descriptor. The data
            // is released immediately after, intentionally — we'll
            // re-read in fetchData if the bridge picks an inline path.
            guard let data = pb.data(forType: type) else { continue }
            descriptors.append(
                ClipboardFormatDescriptor(mime: mime, size: UInt64(data.count))
            )
        }
        return ClipboardSnapshot(token: token, formats: descriptors)
    }

    public func fetchData(mime: String, token: ClipboardSnapshotToken) async -> Data? {
        let pb = NSPasteboard.general
        guard pb.changeCount == token.value else { return nil }
        guard let type = Self.macOSType(for: mime) else { return nil }
        return pb.data(forType: type)
    }

    // MARK: - MIME mapping

    /// Map a macOS pasteboard type to a wire MIME we ship. Returns
    /// nil for anything outside the accepted set so unknown types
    /// silently drop.
    public static func wireMime(for type: NSPasteboard.PasteboardType) -> String? {
        switch type {
        case .string: return "text/plain;charset=utf-8"
        case .html: return "text/html"
        case .png: return "image/png"
        case .URL, .fileURL: return "text/uri-list"
        default: return nil
        }
    }

    /// Inverse of `wireMime` — used by ClipboardSyncManager when
    /// applying an inbound offer to NSPasteboard. Tolerates
    /// `text/plain;charset=…` etc. by canonicalizing.
    public static func macOSType(for mime: String) -> NSPasteboard.PasteboardType? {
        let canon = Self.canonicalMime(mime)
        switch canon {
        case "text/plain": return .string
        case "text/html": return .html
        case "image/png": return .png
        case "text/uri-list": return .URL
        default: return nil
        }
    }

    private static func canonicalMime(_ mime: String) -> String {
        let lower = mime.lowercased()
        if let semicolon = lower.firstIndex(of: ";") {
            return String(lower[..<semicolon]).trimmingCharacters(in: .whitespaces)
        }
        return lower
    }
}
