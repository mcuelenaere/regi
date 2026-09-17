// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import KVMKit
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "clipboard-source")

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
        let rawTypes = pb.types ?? []
        var skipped: [String] = []
        for type in rawTypes {
            guard let mime = Self.wireMime(for: type) else {
                skipped.append(type.rawValue)
                continue
            }
            // NSPasteboard doesn't expose size-without-data; we read
            // here once per snapshot to fill the descriptor. The data
            // is released immediately after, intentionally — we'll
            // re-read in fetchData if the bridge picks an inline path.
            guard let data = pb.data(forType: type) else {
                log.debug("[SOURCE] snapshot: type=\(type.rawValue, privacy: .public) → no data (skipping)")
                continue
            }
            // Never ship a local file path — see `wireMime`.
            if mime == "text/uri-list", Self.isFileURIList(data) {
                skipped.append("\(type.rawValue) (file: URI)")
                continue
            }
            descriptors.append(
                ClipboardFormatDescriptor(mime: mime, size: UInt64(data.count))
            )
        }
        // Files are a separate axis from the content forms above: a
        // representation with a name IS a file, and the peer's file target
        // takes all of them. Announced by name + size from a `stat` — the
        // bytes are streamed off disk when the peer pulls.
        descriptors.append(contentsOf: Self.fileDescriptors(on: pb))

        let summary = descriptors.map { "\($0.fileName ?? $0.mime)(\($0.size))" }.joined(separator: ", ")
        let skippedDesc = skipped.joined(separator: ", ")
        log.debug("[SOURCE] snapshot: token=\(token.value, privacy: .public) raw_types=\(rawTypes.count, privacy: .public) descriptors=[\(summary, privacy: .public)] skipped=[\(skippedDesc, privacy: .public)]")
        return ClipboardSnapshot(token: token, formats: descriptors)
    }

    public func fileURL(fileName: String, token: ClipboardSnapshotToken) async -> URL? {
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount == token.value else {
            log.debug("[SOURCE] fileURL '\(fileName, privacy: .public)' token=\(token.value, privacy: .public): stale (current changeCount=\(currentCount, privacy: .public))")
            return nil
        }
        // Re-derive from the pasteboard rather than caching a map from the
        // snapshot: the token already guarantees we're looking at the same
        // clipboard, and it keeps the source stateless.
        let url = Self.fileURLs(on: pb).first { $0.lastPathComponent == fileName }
        log.debug("[SOURCE] fileURL '\(fileName, privacy: .public)': \(url?.path ?? "not found", privacy: .public)")
        return url
    }

    /// File URLs currently on the pasteboard, in pasteboard order.
    static func fileURLs(on pb: NSPasteboard) -> [URL] {
        let objects = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        return objects ?? []
    }

    /// One descriptor per copied file, skipping anything we can't stream
    /// as a single named file: a directory, a name the receiver would
    /// reject, a path that has gone away, or a duplicate name (two files
    /// with the same name would be indistinguishable to `fileURL`).
    static func fileDescriptors(on pb: NSPasteboard) -> [ClipboardFormatDescriptor] {
        var descriptors: [ClipboardFormatDescriptor] = []
        var seen: Set<String> = []
        for url in fileURLs(on: pb) {
            let name = url.lastPathComponent
            guard (try? ClipboardFileRules.validate(fileName: name)) != nil else {
                log.debug("[SOURCE] snapshot: file '\(name, privacy: .public)' is not transferable; skipping")
                continue
            }
            guard seen.insert(name).inserted else {
                log.debug("[SOURCE] snapshot: duplicate file name '\(name, privacy: .public)'; skipping")
                continue
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let attributes,
                  (attributes[.type] as? FileAttributeType) == .typeRegular
            else {
                // Directories need recursive-copy protocol work nobody has
                // done yet; anything else isn't streamable at all.
                log.debug("[SOURCE] snapshot: '\(name, privacy: .public)' is not a regular file; skipping")
                continue
            }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            descriptors.append(
                ClipboardFormatDescriptor(
                    mime: ClipboardFileRules.mime(forFileName: name),
                    size: size,
                    fileName: name
                )
            )
        }
        return descriptors
    }

    public func fetchData(mime: String, token: ClipboardSnapshotToken) async -> Data? {
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount == token.value else {
            log.debug("[SOURCE] fetchData mime='\(mime, privacy: .public)' token=\(token.value, privacy: .public): stale (current changeCount=\(currentCount, privacy: .public))")
            return nil
        }
        guard let type = Self.macOSType(for: mime) else {
            log.debug("[SOURCE] fetchData mime='\(mime, privacy: .public)': no matching NSPasteboard type; returning nil")
            return nil
        }
        let data = pb.data(forType: type)
        // Mirror the snapshot-side filter, so a representation we never
        // advertised can't be served through a stream open either.
        if let data, mime == "text/uri-list", Self.isFileURIList(data) {
            log.debug("[SOURCE] fetchData mime='\(mime, privacy: .public)': file: URI; withholding local path")
            return nil
        }
        log.debug("[SOURCE] fetchData mime='\(mime, privacy: .public)' type=\(type.rawValue, privacy: .public): \(data?.count ?? -1, privacy: .public) bytes")
        return data
    }

    // MARK: - MIME mapping

    /// Map a macOS pasteboard type to a wire MIME we ship. Returns
    /// nil for anything outside the accepted set so unknown types
    /// silently drop.
    ///
    /// `.fileURL` is deliberately absent. A copied file's URL is a path
    /// in *our* filesystem: it means nothing on the host and needlessly
    /// discloses our directory layout. The protocol carries files as
    /// named representations streamed from disk instead (see
    /// `fileDescriptors(on:)`), so a file copy contributes no
    /// `text/uri-list` at all rather than a broken one.
    public static func wireMime(for type: NSPasteboard.PasteboardType) -> String? {
        switch type {
        case .string: return "text/plain;charset=utf-8"
        case .html: return "text/html"
        case .png: return "image/png"
        case .URL: return "text/uri-list"
        default: return nil
        }
    }

    /// True when a `text/uri-list` body is (or begins with) a `file:`
    /// URI. `.URL` and `.fileURL` overlap on the pasteboard — Finder
    /// populates both for a copied file — so filtering by type alone
    /// isn't enough; we check the bytes too. Comment lines (`#`) are
    /// skipped per RFC 2483.
    static func isFileURIList(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            return trimmed.lowercased().hasPrefix("file:")
        }
        return false
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
