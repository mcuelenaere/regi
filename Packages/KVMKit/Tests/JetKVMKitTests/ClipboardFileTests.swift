import XCTest
@testable import JetKVMKit

/// The receiving rules from tinypipe-protocol's `docs/transfer.md`, plus
/// the temp-file/commit machinery that enforces them. Every case here is
/// one bullet of that document's "Receiving files" section.
final class ClipboardFileTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("regi-file-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    // MARK: - Name validation

    func testAcceptsOrdinaryNames() throws {
        for name in ["report.pdf", "archive.tar.gz", "README", ".zshrc", "eén café.txt", "a b c.bin"] {
            XCTAssertEqual(try ClipboardFileRules.validate(fileName: name), name)
        }
    }

    /// Fails closed: a name that looks wrong is rejected, never rewritten
    /// into a different (possibly existing) file.
    func testRejectsUnsafeNames() {
        let cases: [(String, String)] = [
            ("", "empty"),
            ("../etc/passwd", "parent traversal"),
            ("..", "dot component"),
            (".", "dot component"),
            ("a/b.txt", "unix separator"),
            ("a\\b.txt", "windows separator"),
            ("C:evil.txt", "drive-relative"),
            ("file.txt:stream", "NTFS alternate data stream"),
            ("evil.txt.", "trailing dot"),
            ("evil.txt ", "trailing space"),
            ("bad\u{0}name", "NUL"),
            ("two\nlines.txt", "newline"),
            ("CON", "reserved device name"),
            ("nul.txt", "reserved device name, lowercased"),
            ("COM1.log", "reserved device name with extension"),
            (".regi-part-1234", "our own temp prefix"),
            (".tinypipe-part-1234", "the peer's temp prefix"),
            (String(repeating: "a", count: 201), "over the length cap"),
        ]
        for (name, why) in cases {
            XCTAssertThrowsError(try ClipboardFileRules.validate(fileName: name), why)
        }
    }

    func testCollisionNameKeepsTheExtension() {
        XCTAssertEqual(ClipboardFileRules.collisionName("report.pdf", attempt: 0), "report.pdf")
        XCTAssertEqual(ClipboardFileRules.collisionName("report.pdf", attempt: 1), "report (2).pdf")
        XCTAssertEqual(ClipboardFileRules.collisionName("report.pdf", attempt: 2), "report (3).pdf")
        // Last dot wins, so `.gz` stays the extension.
        XCTAssertEqual(ClipboardFileRules.collisionName("archive.tar.gz", attempt: 1), "archive.tar (2).gz")
        XCTAssertEqual(ClipboardFileRules.collisionName("README", attempt: 1), "README (2)")
        // A leading dot is not an extension separator.
        XCTAssertEqual(ClipboardFileRules.collisionName(".zshrc", attempt: 1), ".zshrc (2)")
    }

    func testMimeGuessMatchesTheAgentsTable() {
        XCTAssertEqual(ClipboardFileRules.mime(forFileName: "notes.txt"), "text/plain")
        XCTAssertEqual(ClipboardFileRules.mime(forFileName: "paper.PDF"), "application/pdf")
        XCTAssertEqual(ClipboardFileRules.mime(forFileName: "shot.png"), "image/png")
        XCTAssertEqual(ClipboardFileRules.mime(forFileName: "blob"), "application/octet-stream")
        XCTAssertEqual(ClipboardFileRules.mime(forFileName: "thing.unknownext"), "application/octet-stream")
    }

    // MARK: - Placement + commit

    func testCommitPublishesUnderTheRequestedName() throws {
        let body = Data("hello".utf8)
        let writer = try ClipboardFileWriter(
            directory: scratch, rawName: "greeting.txt", declaredSize: UInt64(body.count)
        )
        try writer.write(body)
        let url = try writer.commit()

        XCTAssertEqual(url.lastPathComponent, "greeting.txt")
        XCTAssertEqual(try Data(contentsOf: url), body)
        // Nothing left behind.
        XCTAssertEqual(try contents(of: scratch), ["greeting.txt"])
    }

    /// What lands is an ordinary file the user will paste and share. The
    /// temp file is owner-only so nobody can read a partial, but `rename`
    /// carries its mode across, so the relaxation has to happen before the
    /// move.
    func testCommittedFileIsNotOwnerOnly() throws {
        let body = Data("readable".utf8)
        let writer = try ClipboardFileWriter(
            directory: scratch, rawName: "shared.txt", declaredSize: UInt64(body.count)
        )
        try writer.write(body)
        let url = try writer.commit()

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        ).uint16Value
        XCTAssertEqual(mode, 0o644, "landed as \(String(mode, radix: 8))")
    }

    /// A reader must never observe a partial file under the real name, so
    /// the bytes live under a hidden temp name until the very end.
    func testInProgressFileIsNotVisibleUnderTheRealName() throws {
        let writer = try ClipboardFileWriter(
            directory: scratch, rawName: "big.bin", declaredSize: 10
        )
        try writer.write(Data([1, 2, 3]))

        let entries = try contents(of: scratch)
        XCTAssertFalse(entries.contains("big.bin"))
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].hasPrefix(ClipboardFileRules.tempPrefix))
        // And unreadable by anyone else while it is still partial.
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: scratch.appendingPathComponent(entries[0]).path
            )[.posixPermissions] as? NSNumber
        ).uint16Value
        XCTAssertEqual(mode, 0o600)
    }

    func testNeverOverwritesAnExistingFile() throws {
        let existing = scratch.appendingPathComponent("report.pdf")
        try Data("original".utf8).write(to: existing)

        let body = Data("replacement".utf8)
        let writer = try ClipboardFileWriter(
            directory: scratch, rawName: "report.pdf", declaredSize: UInt64(body.count)
        )
        try writer.write(body)
        let url = try writer.commit()

        XCTAssertEqual(url.lastPathComponent, "report (2).pdf")
        XCTAssertEqual(try Data(contentsOf: existing), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: url), body)
    }

    /// Two transfers of the same name run concurrently; both must land.
    func testConcurrentTransfersOfTheSameNameBothLand() throws {
        let a = try ClipboardFileWriter(directory: scratch, rawName: "dup.bin", declaredSize: 1)
        let b = try ClipboardFileWriter(directory: scratch, rawName: "dup.bin", declaredSize: 1)
        try a.write(Data([0xAA]))
        try b.write(Data([0xBB]))

        let first = try a.commit()
        let second = try b.commit()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data([0xAA]))
        XCTAssertEqual(try Data(contentsOf: second), Data([0xBB]))
    }

    // MARK: - Size

    func testDeclaredSizeIsEnforcedIncrementally() throws {
        let writer = try ClipboardFileWriter(directory: scratch, rawName: "capped.bin", declaredSize: 4)
        try writer.write(Data([1, 2, 3]))
        // The write that would exceed the declaration fails, not some later
        // check after the volume has already taken the bytes.
        XCTAssertThrowsError(try writer.write(Data([4, 5]))) { error in
            XCTAssertEqual(error as? ClipboardFileError, .overran(declared: 4))
        }
    }

    func testImplausibleDeclaredSizeIsRefusedBeforeTouchingTheDisk() {
        XCTAssertThrowsError(
            try ClipboardFileWriter(
                directory: scratch,
                rawName: "huge.bin",
                declaredSize: ClipboardFileRules.maxFileBytes + 1
            )
        ) { error in
            XCTAssertEqual(error as? ClipboardFileError, .tooLarge(ClipboardFileRules.maxFileBytes + 1))
        }
        XCTAssertEqual(try? contents(of: scratch), [])
    }

    func testShortTransferIsDiscardedNotPublished() throws {
        let writer = try ClipboardFileWriter(directory: scratch, rawName: "short.bin", declaredSize: 8)
        try writer.write(Data([1, 2, 3]))
        XCTAssertThrowsError(try writer.commit()) { error in
            XCTAssertEqual(error as? ClipboardFileError, .sizeMismatch(declared: 8, actual: 3))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("short.bin").path))
    }

    // MARK: - Cleanup

    func testDiscardRemovesThePartial() throws {
        let writer = try ClipboardFileWriter(directory: scratch, rawName: "gone.bin", declaredSize: 99)
        try writer.write(Data([1, 2, 3]))
        writer.discard()
        XCTAssertEqual(try contents(of: scratch), [])
    }

    /// Releasing the writer is the whole cleanup story for an aborted
    /// transfer — a superseded offer, a cancelled drag, a disconnect.
    func testReleasingAnUncommittedWriterRemovesThePartial() throws {
        do {
            let writer = try ClipboardFileWriter(directory: scratch, rawName: "orphan.bin", declaredSize: 99)
            try writer.write(Data([1, 2, 3]))
            XCTAssertEqual(try contents(of: scratch).count, 1)
        }
        XCTAssertEqual(try contents(of: scratch), [])
    }

    func testSweepOrphansTakesOnlyOurOwnOldDebris() throws {
        let debris = scratch.appendingPathComponent(ClipboardFileRules.tempPrefix + "old")
        let innocent = scratch.appendingPathComponent("keep.txt")
        try Data().write(to: debris)
        try Data().write(to: innocent)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: debris.path
        )

        // Fresh debris is left alone — it may be a live transfer.
        XCTAssertEqual(ClipboardFileRules.sweepOrphans(in: scratch, olderThan: 7200), 0)
        XCTAssertEqual(ClipboardFileRules.sweepOrphans(in: scratch, olderThan: 60), 1)
        XCTAssertEqual(try contents(of: scratch), ["keep.txt"])
    }
}
