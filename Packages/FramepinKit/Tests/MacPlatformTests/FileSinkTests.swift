import Domain
import Foundation
import Synchronization
import Testing

@testable import MacPlatform

/// Real POSIX file operations with scripted failures at the write or commit step.
final class FaultInjectingFileSystem: FileSystemOperations {
    let base = POSIXFileSystem()
    let failWrite: Int32?
    let failCommit: Int32?

    init(failWrite: Int32? = nil, failCommit: Int32? = nil) {
        self.failWrite = failWrite
        self.failCommit = failCommit
    }

    func writeNewFile(_ data: Data, at url: URL) throws(FileSystemFailure) {
        if let failWrite {
            // Leave a partial temporary file behind, as a real mid-write failure would.
            try base.writeNewFile(data.prefix(3), at: url)
            throw FileSystemFailure(code: failWrite)
        }
        try base.writeNewFile(data, at: url)
    }

    func moveExclusively(from source: URL, to destination: URL) throws(FileSystemFailure) {
        if let failCommit { throw FileSystemFailure(code: failCommit) }
        try base.moveExclusively(from: source, to: destination)
    }

    func replace(from source: URL, to destination: URL) throws(FileSystemFailure) {
        if let failCommit { throw FileSystemFailure(code: failCommit) }
        try base.replace(from: source, to: destination)
    }

    func removeItem(at url: URL) { base.removeItem(at: url) }
    func itemExists(at url: URL) -> Bool { base.itemExists(at: url) }
}

@Suite("File sink: atomic, collision-safe, failure-preserving saves (FR-07, EXP-02)")
struct FileSinkTests {
    let snapshot = TestSupport.snapshot()
    let priorBytes = Data("prior destination".utf8)

    @Test("A new file receives exactly the snapshot bytes and no temporary file remains")
    func savesAtomically() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        let saved = try FileSink().save(snapshot, to: url, overwrite: false)
        #expect(saved == url)
        #expect(try Data(contentsOf: url) == snapshot.bytes)
        #expect(TestSupport.directoryEntries(folder) == ["shot.png"])
    }

    @Test("An existing destination is refused without the overwrite flag and stays intact")
    func refusesOverwrite() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        #expect(throws: SinkError.destinationExists) { try FileSink().save(snapshot, to: url, overwrite: false) }
        #expect(try Data(contentsOf: url) == priorBytes)
        #expect(TestSupport.directoryEntries(folder) == ["shot.png"])
    }

    @Test("The overwrite flag replaces the destination atomically")
    func overwritesWhenAsked() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        _ = try FileSink().save(snapshot, to: url, overwrite: true)
        #expect(try Data(contentsOf: url) == snapshot.bytes)
        #expect(TestSupport.directoryEntries(folder) == ["shot.png"])
    }

    @Test("Unique saves add a counter before the extension on collision")
    func uniqueNames() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let sink = FileSink()
        let names = try (0..<3).map { _ in try sink.saveUnique(snapshot, in: folder).lastPathComponent }
        let base = "Framepin 2026-09-26 at 10.00.00"
        #expect(names == ["\(base).png", "\(base) (2).png", "\(base) (3).png"])
        #expect(TestSupport.directoryEntries(folder).count == 3)
    }

    @Test(
        "Suggested names cannot escape the folder, hide the file, or be empty",
        arguments: [
            ("../../escape/x.png", "x.png"),
            ("a:b/c:d.png", "c-d.png"),
            ("..hidden.png", "hidden.png"),
            ("", "Framepin.png"),
            ("/", "Framepin.png"),
            ("tab\tname\u{0}.png", "tab-name-.png"),
        ])
    func sanitizedNames(suggested: String, expected: String) throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = try FileSink().saveUnique(TestSupport.snapshot(suggestedFilename: suggested), in: folder)
        #expect(url.lastPathComponent == expected)
        #expect(url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(TestSupport.directoryEntries(folder) == [expected])
    }

    @Test(
        "Write failures map to typed errors, keep the prior file, and remove the temporary file",
        arguments: [
            (ENOSPC, SinkError.diskFull),
            (EDQUOT, .diskFull),
            (EACCES, .accessDenied),
            (EPERM, .accessDenied),
            (EROFS, .accessDenied),
            (ENOENT, .volumeUnavailable),
            (ENXIO, .volumeUnavailable),
            (ENODEV, .volumeUnavailable),
            (EIO, .writeFailed(code: Int(EIO))),
        ])
    func injectedWriteFailures(code: Int32, expected: SinkError) throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        let sink = FileSink(fileSystem: FaultInjectingFileSystem(failWrite: code))
        #expect(throws: expected) { try sink.save(snapshot, to: url, overwrite: true) }
        #expect(try Data(contentsOf: url) == priorBytes)
        #expect(TestSupport.directoryEntries(folder) == ["shot.png"])
    }

    @Test("A failed commit keeps the prior file and removes the temporary file")
    func injectedCommitFailure() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        let sink = FileSink(fileSystem: FaultInjectingFileSystem(failCommit: ENOSPC))
        #expect(throws: SinkError.diskFull) { try sink.save(snapshot, to: url, overwrite: true) }
        #expect(throws: SinkError.diskFull) { try sink.saveUnique(snapshot, in: folder) }
        #expect(try Data(contentsOf: url) == priorBytes)
        #expect(TestSupport.directoryEntries(folder) == ["shot.png"])
    }

    @Test("A missing destination folder is an unavailable volume")
    func missingFolder() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let gone = folder.appendingPathComponent("unplugged", isDirectory: true)
        #expect(throws: SinkError.volumeUnavailable) { try FileSink().saveUnique(snapshot, in: gone) }
        #expect(throws: SinkError.volumeUnavailable) {
            try FileSink().save(snapshot, to: gone.appendingPathComponent("x.png"), overwrite: false)
        }
    }

    @Test("A read-only folder is access denied and gains no files")
    func readOnlyFolder() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            TestSupport.removeDirectory(folder)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        #expect(throws: SinkError.accessDenied) { try FileSink().saveUnique(snapshot, in: folder) }
        #expect(TestSupport.directoryEntries(folder).isEmpty)
    }
}
