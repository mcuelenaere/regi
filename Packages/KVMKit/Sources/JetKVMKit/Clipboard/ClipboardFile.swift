// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "clipboard-file")

/// Safety rules and on-disk plumbing for representations that carry a
/// `file_name` — clipboard file copy/paste and drag-and-drop both land
/// their bytes through here.
///
/// `file_name` and `size` are peer-supplied and untrusted. The rules
/// below are `docs/transfer.md`'s "Receiving files" section, not our
/// invention; a conforming sender never trips them, so failing closed is
/// always safe:
///
/// - **Name** — exactly one path component. Rejected, never rewritten: a
///   name that *looks* wrong must not silently become a different
///   (possibly existing) file.
/// - **Placement** — bytes go to a hidden temp file *in the destination
///   directory*, so the finishing move is a same-filesystem rename and a
///   reader never sees a partial file under the real name.
/// - **Overwrite** — the final name is claimed with `O_EXCL`; collisions
///   fall through to ` (2)`, ` (3)`, …. An existing file is never
///   clobbered, and two concurrent transfers of the same name both land.
/// - **Size** — preflighted against free space and an absolute ceiling
///   before we accept, then enforced *incrementally* while writing.
/// - **Cleanup** — `ClipboardFileWriter` unlinks its temp file on deinit
///   unless it committed, which covers failures, cancels, superseded
///   offers, and disconnects alike. `sweepOrphans` clears what a crash
///   left behind.
public enum ClipboardFileRules {
    /// Longest accepted file name, in bytes. Below the usual 255-byte
    /// filesystem limit so a collision suffix still fits.
    public static let maxFileNameBytes: Int = 200

    /// Absolute ceiling on one received file. Free space is the real
    /// guard; this rejects a wildly bogus declared `size` before we touch
    /// the filesystem. Matches tinypipe's own limit.
    public static let maxFileBytes: UInt64 = 8 * 1024 * 1024 * 1024

    /// Free space to leave unconsumed, so accepting a file can't fill the
    /// destination volume as a side effect.
    public static let freeSpaceHeadroom: UInt64 = 64 * 1024 * 1024

    /// Prefix for in-progress temp files: hidden, and recognizable enough
    /// that `sweepOrphans` only ever deletes our own debris.
    public static let tempPrefix: String = ".regi-part-"

    /// tinypipe's equivalent prefix. Rejected in a received name for the
    /// same reason ours is — a sweep on either side must not mistake a
    /// committed file for debris.
    static let peerTempPrefix: String = ".tinypipe-part-"

    /// How many ` (n)` variants to try before giving up on a name.
    static let maxCollisionTries: Int = 999

    /// Windows reserved device names, checked on every platform: a
    /// received tree may be read from Windows later, where a file called
    /// `NUL` is at best unusable.
    static let reservedStems: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ]

    /// Validate a peer-supplied file name as a single safe path
    /// component, returning it unchanged. Throws rather than sanitizing —
    /// see the type docs.
    ///
    /// Also used on the *outbound* side, so we never announce a file whose
    /// transfer the peer is guaranteed to refuse.
    public static func validate(fileName raw: String) throws -> String {
        func reject(_ why: String) -> ClipboardFileError {
            .unsafeName(raw, reason: why)
        }

        if raw.isEmpty { throw reject("empty") }
        if raw.utf8.count > maxFileNameBytes { throw reject("longer than \(maxFileNameBytes) bytes") }
        // NUL, newlines and friends: never legitimate, and a classic way to
        // make a name read differently to a shell, a log, or a UI than it
        // does to the filesystem.
        if raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw reject("control character")
        }
        // Both separators regardless of host: the peer may run a different
        // OS, and a `\` that is an ordinary character here is a separator
        // over there.
        if raw.contains("/") || raw.contains("\\") { throw reject("path separator") }
        // Drive-relative paths (`C:file`) and NTFS alternate data streams.
        if raw.contains(":") { throw reject("colon (drive or NTFS alternate data stream)") }
        if raw == "." || raw == ".." { throw reject("dot component") }
        // Windows silently strips these, so `evil.txt.` would land as
        // `evil.txt` — a name we never validated as the destination.
        if raw.hasSuffix(".") || raw.hasSuffix(" ") { throw reject("trailing dot or space") }
        if raw.hasPrefix(tempPrefix) || raw.hasPrefix(peerTempPrefix) {
            throw reject("reserved temp-file prefix")
        }
        let stem = (raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? raw).uppercased()
        if reservedStems.contains(stem) { throw reject("Windows reserved device name") }
        // Belt and braces: after the checks above, the OS's own parse of the
        // name must still yield exactly this one component.
        if (raw as NSString).lastPathComponent != raw { throw reject("not a single path component") }
        return raw
    }

    /// `name` for `attempt == 0`, then `stem (2).ext`, `stem (3).ext`, … —
    /// the suffix goes before the extension, so `report.pdf` becomes
    /// `report (2).pdf`.
    static func collisionName(_ name: String, attempt: Int) -> String {
        if attempt == 0 { return name }
        let n = attempt + 1
        // Split on the LAST dot so `archive.tar.gz` keeps `.gz`; a leading
        // dot (dotfile) is not an extension separator.
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return "\(name) (\(n))"
        }
        return "\(name[name.startIndex..<dot]) (\(n))\(name[dot...])"
    }

    /// Informational wire MIME for a file we're announcing, guessed from
    /// its extension. The receiver treats a file's MIME as advisory — it
    /// lands as an OS file reference, not a rendered flavor — so an
    /// unrecognized extension falling back to `application/octet-stream`
    /// costs nothing. Mirrors tinypipe's table so both directions agree.
    public static func mime(forFileName name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "txt", "log", "md", "csv", "ini", "cfg", "conf": return "text/plain"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js", "mjs": return "application/javascript"
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "yaml", "yml": return "application/yaml"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        case "ico": return "image/vnd.microsoft.icon"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "gz", "tgz": return "application/gzip"
        case "bz2": return "application/x-bzip2"
        case "xz": return "application/x-xz"
        case "7z": return "application/x-7z-compressed"
        case "rar": return "application/vnd.rar"
        case "zst": return "application/zstd"
        case "tar": return "application/x-tar"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }

    /// Delete temp files in `directory` left over from a previous run — a
    /// crash skips `ClipboardFileWriter`'s deinit, so debris is possible
    /// even though every normal path cleans up after itself. Only files
    /// carrying `tempPrefix` and older than `minAge` go, so a live
    /// transfer is left alone. Returns how many were removed.
    @discardableResult
    public static func sweepOrphans(in directory: URL, olderThan minAge: TimeInterval) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return 0 }
        var removed = 0
        for entry in entries where entry.lastPathComponent.hasPrefix(tempPrefix) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            // A timestamp we can't read, or one in the future: leave it be.
            guard let modified, Date().timeIntervalSince(modified) >= minAge else { continue }
            if (try? fm.removeItem(at: entry)) != nil { removed += 1 }
        }
        if removed > 0 {
            log.debug("[FILE] swept \(removed, privacy: .public) orphaned temp file(s) from \(directory.path, privacy: .public)")
        }
        return removed
    }
}

public enum ClipboardFileError: Swift.Error, Equatable {
    case unsafeName(String, reason: String)
    /// Declared `size` over `ClipboardFileRules.maxFileBytes`.
    case tooLarge(UInt64)
    case noSpace(needed: UInt64, available: UInt64)
    /// Every ` (n)` variant of the name was taken.
    case nameTaken(String)
    /// The peer streamed more than it declared.
    case overran(declared: UInt64)
    /// The transfer finished at a length other than the declared `size`.
    case sizeMismatch(declared: UInt64, actual: UInt64)
    case io(String)
}

/// One inbound file, mid-flight. Owns a hidden temp file in the
/// destination directory until `commit()` moves it into place or the
/// writer is released, which unlinks it.
///
/// Releasing is the whole cleanup story: a superseded offer, a cancelled
/// drag, a channel drop and an error return all simply stop referencing
/// the writer, and the partial file goes with it.
final class ClipboardFileWriter {
    /// The validated name the peer asked for. The name actually committed
    /// may carry a ` (2)` suffix.
    let requestedName: String
    let declaredSize: UInt64

    private let directory: URL
    private let tempURL: URL
    private var descriptor: Int32
    private(set) var written: UInt64 = 0
    private var committed = false

    /// Prepare to receive one file into `directory`: validate the name,
    /// reject an implausible size, preflight free space, and open a hidden
    /// temp file on the destination's own filesystem.
    ///
    /// `alreadyReserved` is what the caller has accepted but not yet
    /// written — the other files of the same offer. Without it every file
    /// of a 20-file offer would pass the same free-space check before any
    /// of them had written a byte, and together they'd still fill the
    /// volume.
    init(directory: URL, rawName: String, declaredSize: UInt64, alreadyReserved: UInt64 = 0) throws {
        self.requestedName = try ClipboardFileRules.validate(fileName: rawName)
        self.declaredSize = declaredSize
        self.directory = directory

        guard declaredSize <= ClipboardFileRules.maxFileBytes else {
            throw ClipboardFileError.tooLarge(declaredSize)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ClipboardFileError.io("create \(directory.path): \(error.localizedDescription)")
        }
        try Self.preflightSpace(
            in: directory,
            need: declaredSize.addingReportingOverflow(alreadyReserved).partialValue
        )

        // Unique per transfer, so two concurrent files headed for the same
        // destination name don't share a temp path.
        let unique = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))"
        self.tempURL = directory.appendingPathComponent(ClipboardFileRules.tempPrefix + unique)
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw ClipboardFileError.io("open \(tempURL.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        self.descriptor = fd
    }

    deinit {
        if !committed { discard() }
    }

    /// Append the next slice. The declared size is enforced here rather
    /// than only at the end, so a peer that streams more than it announced
    /// fails on the offending write instead of after filling the volume.
    func write(_ data: Data) throws {
        if data.isEmpty { return }
        guard written + UInt64(data.count) <= declaredSize else {
            throw ClipboardFileError.overran(declared: declaredSize)
        }
        var remaining = data
        while !remaining.isEmpty {
            let n: Int = remaining.withUnsafeBytes { raw in
                Darwin.write(descriptor, raw.baseAddress, raw.count)
            }
            guard n > 0 else {
                throw ClipboardFileError.io("write: \(String(cString: strerror(errno)))")
            }
            written &+= UInt64(n)
            remaining = remaining.dropFirst(n)
        }
    }

    /// Verify the length, claim a free destination name, and rename the
    /// finished temp file onto it. Returns the committed URL.
    func commit() throws -> URL {
        guard written == declaredSize else {
            throw ClipboardFileError.sizeMismatch(declared: declaredSize, actual: written)
        }
        // The temp file is 0600 so nobody can read a partial transfer, but
        // `rename` carries that mode onto the destination — and what lands
        // is an ordinary file the user will paste, copy and share like any
        // other. Relax it to the conventional 0644 before the move, not
        // after, so the mode is never wrong under the final name.
        if fchmod(descriptor, 0o644) != 0 {
            log.error("[FILE] chmod \(self.requestedName, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
        }
        closeDescriptor()
        let destination = try claimDestination()
        // Plain POSIX rename: atomic, same filesystem (the temp file lives in
        // the destination directory), and it replaces the empty placeholder
        // `claimDestination` just created.
        guard rename(tempURL.path, destination.path) == 0 else {
            let why = String(cString: strerror(errno))
            // Don't leave the placeholder squatting a name we failed to fill.
            try? FileManager.default.removeItem(at: destination)
            throw ClipboardFileError.io("rename into \(destination.lastPathComponent): \(why)")
        }
        committed = true
        log.debug("[FILE] committed \(destination.path, privacy: .public) (\(self.written, privacy: .public) bytes)")
        return destination
    }

    /// Close and unlink the temp file. Idempotent.
    func discard() {
        closeDescriptor()
        guard !committed else { return }
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
            log.debug("[FILE] discarded partial \(self.tempURL.lastPathComponent, privacy: .public) (\(self.written, privacy: .public)/\(self.declaredSize, privacy: .public) bytes)")
        }
    }

    private func closeDescriptor() {
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
    }

    /// Reserve the final name by *creating* it, so an existing file (or a
    /// concurrent transfer grabbing the same moment) can never be
    /// overwritten — `O_EXCL` is atomic.
    ///
    /// Between this and the `rename` the destination exists as a 0-byte
    /// placeholder, and a crash in that window leaves it behind (the next
    /// transfer of the same name then disambiguates around it). That's the
    /// price of claiming the name atomically; the alternative — check then
    /// rename — is a TOCTOU race that can clobber a real file.
    private func claimDestination() throws -> URL {
        for attempt in 0...ClipboardFileRules.maxCollisionTries {
            let candidate = directory.appendingPathComponent(
                ClipboardFileRules.collisionName(requestedName, attempt: attempt)
            )
            let fd = open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 {
                close(fd)
                return candidate
            }
            // Taken by a file, a directory, or a racing transfer — next variant.
            if errno == EEXIST { continue }
            throw ClipboardFileError.io("claim \(candidate.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        throw ClipboardFileError.nameTaken(requestedName)
    }

    /// Refuse the transfer if accepting it would eat into the headroom.
    private static func preflightSpace(in directory: URL, need: UInt64) throws {
        let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = values?.volumeAvailableCapacityForImportantUsage else {
            // Can't tell — the incremental cap and `maxFileBytes` still bound
            // the damage, so don't refuse a transfer over a missing stat.
            return
        }
        let required = need.addingReportingOverflow(ClipboardFileRules.freeSpaceHeadroom).partialValue
        guard UInt64(max(0, available)) >= required else {
            throw ClipboardFileError.noSpace(needed: required, available: UInt64(max(0, available)))
        }
    }
}

/// Chunked reader for an outbound file representation.
///
/// Files are never inlined and never slurped: announcing and serving a
/// 10 GiB file costs the same resident memory as a 10 KiB one, which is
/// the whole reason `ClipboardSource` grew a URL-returning variant
/// alongside `fetchData(mime:token:)`.
final class ClipboardFileReader {
    private var descriptor: Int32

    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw ClipboardFileError.io("open \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        self.descriptor = fd
    }

    deinit { close() }

    /// Next slice, or empty at EOF.
    func read(upTo count: Int) throws -> Data {
        var buffer = Data(count: count)
        let n: Int = buffer.withUnsafeMutableBytes { raw in
            Darwin.read(descriptor, raw.baseAddress, raw.count)
        }
        guard n >= 0 else {
            throw ClipboardFileError.io("read: \(String(cString: strerror(errno)))")
        }
        return n == count ? buffer : buffer.prefix(n)
    }

    /// Idempotent.
    func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
}
