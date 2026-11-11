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

    func writeNewFile(_ data: Data, at url: URL, permissions: mode_t) throws(FileSystemFailure) {
        if let failWrite {
            // Leave a partial temporary file behind, as a real mid-write failure would.
            try base.writeNewFile(data.prefix(3), at: url, permissions: permissions)
            throw FileSystemFailure(code: failWrite)
        }
        try base.writeNewFile(data, at: url, permissions: permissions)
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

/// Real POSIX file operations that let a test act on the temporary file after it is written and
/// before it is committed, as another account sharing the folder could.
final class InterposingFileSystem: FileSystemOperations {
    let base = POSIXFileSystem()
    let afterWrite: (URL) -> Void

    init(afterWrite: @escaping (URL) -> Void) {
        self.afterWrite = afterWrite
    }

    func writeNewFile(_ data: Data, at url: URL, permissions: mode_t) throws(FileSystemFailure) {
        try base.writeNewFile(data, at: url, permissions: permissions)
        afterWrite(url)
    }

    func moveExclusively(from source: URL, to destination: URL) throws(FileSystemFailure) {
        try base.moveExclusively(from: source, to: destination)
    }

    func replace(from source: URL, to destination: URL) throws(FileSystemFailure) {
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

    @Test("Unique saves add a counter before the extension on collision")
    func uniqueNames() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let sink = FileSink()
        let names = try (0..<3).map { _ in try sink.saveUnique(snapshot, in: folder).lastPathComponent }
        let base = "Recortia 2026-09-26 at 10.00.00"
        #expect(names == ["\(base).png", "\(base) (2).png", "\(base) (3).png"])
        #expect(TestSupport.directoryEntries(folder).count == 3)
    }

    @Test(
        "Suggested names cannot escape the folder, hide the file, or be empty",
        arguments: [
            ("../../escape/x.png", "x.png"),
            ("a:b/c:d.png", "c-d.png"),
            ("..hidden.png", "hidden.png"),
            ("", "Recortia.png"),
            ("/", "Recortia.png"),
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

    @Test("Overwriting keeps the replaced file's permissions, so a restricted file stays restricted")
    func overwriteKeepsPermissions() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        _ = try FileSink().save(snapshot, to: url, overwrite: true)
        #expect(try Data(contentsOf: url) == snapshot.bytes)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o640)
    }

    @Test("Overwriting keeps an explicit ACL entry on the replaced file")
    func overwriteKeepsACL() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read", url.path(percentEncoded: false)]
        try chmod.run()
        chmod.waitUntilExit()
        try #require(chmod.terminationStatus == 0, "control: chmod +a could not set the synthetic entry")
        let before = try #require(Self.extendedACL(url), "control: the destination has no explicit ACL")
        _ = try FileSink().save(snapshot, to: url, overwrite: true)
        #expect(try Data(contentsOf: url) == snapshot.bytes)
        #expect(Self.extendedACL(url) == before, "the replaced file lost its ACL")
    }

    // Failure mode (second review of R-4): the destination's ACL is copied onto the temporary file
    // before the rename. When it denies this user delete, the rename is refused and, unless the
    // copy is undone, so is the cleanup, stranding a complete export after a reported failure.
    @Test("A refused overwrite of a file whose ACL denies delete leaves it intact and no temporary file")
    func refusedOverwriteLeavesNoTemporaryFile() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer {
            Self.clearACLs(in: folder)
            TestSupport.removeDirectory(folder)
        }
        let denyDelete = "\(NSUserName()) deny delete"
        // Control: in this directory the entry really refuses both replacing and unlinking the file.
        let control = folder.appendingPathComponent("control.png")
        let replacement = folder.appendingPathComponent("control-new.png")
        try priorBytes.write(to: control)
        try priorBytes.write(to: replacement)
        try Self.addACL(denyDelete, to: control)
        let renameResult = rename(replacement.path(percentEncoded: false), control.path(percentEncoded: false))
        let renameErrno = errno
        let unlinkResult = unlink(control.path(percentEncoded: false))
        let unlinkErrno = errno
        try #require(
            renameResult != 0 && unlinkResult != 0,
            "control: the ACL did not stop replace/unlink (rename \(renameResult)/\(renameErrno), unlink \(unlinkResult)/\(unlinkErrno))"
        )
        Self.clearACLs(in: folder)
        try FileManager.default.removeItem(at: control)
        try FileManager.default.removeItem(at: replacement)

        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        try Self.addACL(denyDelete, to: url)
        #expect(throws: SinkError.accessDenied) { try FileSink().save(snapshot, to: url, overwrite: true) }
        #expect(try Data(contentsOf: url) == priorBytes)
        #expect(TestSupport.directoryEntries(folder) == ["shot.png"], "a temporary export was left behind")
    }

    enum Swap: String, CaseIterable, Sendable {
        case symlink, hardLink
    }

    // NV-01 (pre-release security audit): the temporary file was closed after writing and its
    // mode and ACL were later set by pathname. Another account that may rename entries in a
    // shared, non-sticky folder could swap that name for a link to an unrelated file of the person
    // in between, and the destination's access would then be applied to the unrelated file.
    @Test(
        "A temporary file swapped for a link to another file is refused and the other file is untouched",
        arguments: Swap.allCases)
    func swappedTemporaryFileIsRefused(swap: Swap) throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer {
            Self.clearACLs(in: folder)
            TestSupport.removeDirectory(folder)
        }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try Self.addACL("everyone allow write", to: url)
        let victimBytes = Data("unrelated private file".utf8)
        let victim = folder.appendingPathComponent("victim.txt")
        try victimBytes.write(to: victim)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: victim.path)
        try #require(Self.extendedACL(victim) == nil, "control: the victim already has an ACL")

        let observed = Observation()
        let fileSystem = InterposingFileSystem { temporary in
            // Keep the real temporary file under another name, so cleanup is still the sink's job.
            let aside = folder.appendingPathComponent("moved-aside")
            guard rename(temporary.path(percentEncoded: false), aside.path(percentEncoded: false)) == 0 else { return }
            let linked =
                switch swap {
                case .symlink: symlink(victim.path(percentEncoded: false), temporary.path(percentEncoded: false))
                case .hardLink: link(victim.path(percentEncoded: false), temporary.path(percentEncoded: false))
                }
            guard linked == 0 else { return }
            observed.swapResolvesToVictim =
                Self.inode(temporary) == Self.inode(victim)
                && Self.isSymbolicLink(temporary) == (swap == .symlink)
        }
        #expect(throws: SinkError.accessDenied) {
            try FileSink(fileSystem: fileSystem).save(snapshot, to: url, overwrite: true)
        }
        try #require(observed.swapResolvesToVictim, "control: the temporary name never pointed at the victim")
        #expect(!Self.isSymbolicLink(url), "the destination became a link")
        #expect(try Data(contentsOf: url) == priorBytes)
        #expect(try Data(contentsOf: victim) == victimBytes)
        #expect(Self.mode(victim) == 0o600, "the destination's mode reached the victim")
        #expect(Self.extendedACL(victim) == nil, "the destination's ACL reached the victim")
        #expect(!TestSupport.directoryEntries(folder).contains { $0.hasPrefix(".recortia-") })
    }

    @Test("A temporary file that gained a second name before the commit is refused")
    func temporaryFileWithSecondNameIsRefused() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        let observed = Observation()
        let fileSystem = InterposingFileSystem { temporary in
            let second = folder.appendingPathComponent("second-name")
            observed.swapResolvesToVictim =
                link(temporary.path(percentEncoded: false), second.path(percentEncoded: false)) == 0
        }
        #expect(throws: SinkError.accessDenied) {
            try FileSink(fileSystem: fileSystem).save(snapshot, to: url, overwrite: true)
        }
        try #require(observed.swapResolvesToVictim, "control: the second name was not created")
        #expect(try Data(contentsOf: url) == priorBytes)
    }

    // NV-02 (pre-release security audit): the temporary file is created in the destination folder,
    // so an inheritable folder entry reached it and the new bytes were readable by others while
    // being written, and stayed so after replacing a private file.
    @Test("Replacing a private file in a folder with an inheritable entry never exposes the new bytes")
    func inheritedEntryNeverReachesReplacement() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Self.addACL("everyone allow read,file_inherit", to: folder)
        try #require(Self.extendedACL(url) == nil, "control: the destination has an ACL of its own")
        let control = try Self.plainFileACL(in: folder)
        try #require(control?.contains("everyone") == true, "control: the folder entry is not inherited")

        let observed = Observation()
        let fileSystem = InterposingFileSystem { temporary in
            observed.temporaryACL = Self.extendedACL(temporary)
        }
        _ = try FileSink(fileSystem: fileSystem).save(snapshot, to: url, overwrite: true)
        #expect(observed.temporaryACL == nil, "the temporary file carried an inherited entry")
        #expect(try Data(contentsOf: url) == snapshot.bytes)
        #expect(Self.extendedACL(url) == nil, "the replaced private file gained an entry")
        #expect(Self.mode(url) == 0o600)
    }

    enum NewSave: String, CaseIterable, Sendable {
        case save, overwriteMissing, saveUnique
    }

    @Test(
        "A new file in a folder with an inheritable entry carries what a plainly created file gets",
        arguments: NewSave.allCases)
    func newSaveKeepsFolderInheritance(kind: NewSave) throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        try Self.addACL("everyone allow read,file_inherit", to: folder)
        let control = try Self.plainFileACL(in: folder)
        try #require(control?.contains("everyone") == true, "control: the folder entry is not inherited")
        let url = folder.appendingPathComponent("shot.png")
        let saved =
            switch kind {
            case .save: try FileSink().save(snapshot, to: url, overwrite: false)
            case .overwriteMissing: try FileSink().save(snapshot, to: url, overwrite: true)
            case .saveUnique: try FileSink().saveUnique(snapshot, in: folder)
            }
        #expect(try Data(contentsOf: saved) == snapshot.bytes)
        #expect(Self.extendedACL(saved) == control, "the new file lost the folder's inherited entry")
        #expect(TestSupport.directoryEntries(folder) == [saved.lastPathComponent])
    }

    final class Observation {
        var swapResolvesToVictim = false
        var temporaryACL: String?
    }

    /// The ACL a file created plainly in `folder` receives; the file is removed again.
    private static func plainFileACL(in folder: URL) throws -> String? {
        let plain = folder.appendingPathComponent("plain-control")
        try Data().write(to: plain)
        defer { try? FileManager.default.removeItem(at: plain) }
        return extendedACL(plain)
    }

    private static func mode(_ url: URL) -> mode_t? {
        var status = stat()
        guard lstat(url.path(percentEncoded: false), &status) == 0 else { return nil }
        return status.st_mode & 0o7777
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path(percentEncoded: false), &status) == 0 && status.st_mode & S_IFMT == S_IFLNK
    }

    /// The inode `url` resolves to, following a symbolic link.
    private static func inode(_ url: URL) -> ino_t? {
        var status = stat()
        return stat(url.path(percentEncoded: false), &status) == 0 ? status.st_ino : nil
    }

    private static func addACL(_ entry: String, to url: URL) throws {
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", entry, url.path(percentEncoded: false)]
        try chmod.run()
        chmod.waitUntilExit()
        try #require(chmod.terminationStatus == 0, "control: chmod +a could not set \(entry)")
    }

    /// Removes every explicit ACL in `folder`, so a deny entry cannot keep its files undeletable.
    private static func clearACLs(in folder: URL) {
        guard let empty = acl_init(0) else { return }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [] {
            _ = acl_set_file(folder.appendingPathComponent(name).path(percentEncoded: false), ACL_TYPE_EXTENDED, empty)
        }
    }

    /// The file's explicit ACL as text, or nil when it has none.
    private static func extendedACL(_ url: URL) -> String? {
        guard let acl = acl_get_file(url.path(percentEncoded: false), ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(text) }
        return String(cString: text)
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

}
