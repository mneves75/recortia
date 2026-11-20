import Domain
import Foundation
import Synchronization
import Testing

@testable import MacPlatform

extension POSIXFileSystem {
    /// Real POSIX file operations that let a test act on the stage after it is written and before
    /// it is published, as another process could.
    static func interposing(_ beforePublish: @escaping (URL) -> Void) -> POSIXFileSystem {
        POSIXFileSystem(beforePublish: beforePublish)
    }
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
        #expect(saved.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path)
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
        let sink = FileSink(fileSystem: POSIXFileSystem(failWrite: code))
        #expect(throws: expected) { try sink.save(snapshot, to: url, overwrite: true) }
        #expect(try Data(contentsOf: url) == priorBytes)
        #expect(TestSupport.directoryEntries(folder) == ["shot.png"])
    }

    // R11 (second review of T1a): a write(2) that reported zero bytes looped forever.
    @Test("A stage write that makes no progress is an I/O failure that keeps the prior file")
    func zeroProgressStageWriteFails() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        let sink = FileSink(fileSystem: POSIXFileSystem(writeBytes: { _, _, _ in 0 }))
        #expect(throws: SinkError.writeFailed(code: Int(EIO))) { try sink.save(snapshot, to: url, overwrite: true) }
        #expect(try Data(contentsOf: url) == priorBytes)
        #expect(TestSupport.directoryEntries(folder) == ["shot.png"])
    }

    @Test("A failed commit keeps the prior file and removes the temporary file")
    func injectedCommitFailure() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        let sink = FileSink(fileSystem: POSIXFileSystem(failPublish: ENOSPC))
        #expect(throws: SinkError.diskFull) { try sink.save(snapshot, to: url, overwrite: true) }
        #expect(throws: SinkError.diskFull) { try sink.saveUnique(snapshot, in: folder) }
        #expect(try Data(contentsOf: url) == priorBytes)
        #expect(TestSupport.directoryEntries(folder) == ["shot.png"])
    }

    // R01 (adversarial review of T1a): a no-overwrite save renamed the stage by name without
    // checking it was still the file written, so a substituted stage was published as the save.
    @Test(
        "A stage substituted before a new save is published is refused and never appears under the name",
        arguments: [false, true])
    func substitutedStageIsNeverPublished(unique: Bool) throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let marker = Data("not the sanitized snapshot".utf8)
        var substituted = false
        let sink = FileSink(
            fileSystem: POSIXFileSystem(afterSync: { stage in
                let planted = stage.deletingLastPathComponent().appendingPathComponent("planted.tmp")
                substituted =
                    (try? marker.write(to: planted)) != nil
                    && rename(planted.path(percentEncoded: false), stage.path(percentEncoded: false)) == 0
            }))
        let url = folder.appendingPathComponent("shot.png")
        #expect(throws: SinkError.accessDenied) {
            if unique {
                _ = try sink.saveUnique(snapshot, in: folder)
            } else {
                _ = try sink.save(snapshot, to: url, overwrite: false)
            }
        }
        try #require(substituted, "control: the stage was never substituted")
        for name in TestSupport.directoryEntries(folder) where !name.hasPrefix(".recortia-") {
            #expect(
                (try? Data(contentsOf: folder.appendingPathComponent(name))) != marker,
                "the substituted bytes were published as \(name)")
        }
    }

    enum Redirect: String, CaseIterable, Sendable {
        /// The chosen folder's own name became a link.
        case folder
        /// A folder above it became a link to a look-alike tree.
        case ancestor
    }

    // N03 (second review of T1a): admission compared the opened folder's path with the spelling it
    // was given, so a folder reached through a link the system resolves was refused. Contract
    // (decisions.md, "File-save guarantees by volume class"): the folder is admitted by identity;
    // a link resolved before admission leads to the same folder, so the save lands there. A link
    // planted before admission is R06, a declined known limit stated in FileSink's header.
    @Test(
        "A save to a folder spelled through a link lands in the folder the link resolves to",
        arguments: Redirect.allCases)
    func linkedFolderSpellingIsAdmitted(redirect: Redirect) throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(root) }
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(
            at: elsewhere.appendingPathComponent("shots"), withIntermediateDirectories: true)
        let chosen: URL
        switch redirect {
        case .folder:
            chosen = root.appendingPathComponent("shots", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: chosen, withDestinationURL: elsewhere.appendingPathComponent("shots"))
        case .ancestor:
            let parent = root.appendingPathComponent("team", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: elsewhere)
            chosen = parent.appendingPathComponent("shots", isDirectory: true)
        }
        let resolved = elsewhere.appendingPathComponent("shots", isDirectory: true)
        _ = try FileSink().save(snapshot, to: chosen.appendingPathComponent("shot.png"), overwrite: false)
        let unique = try FileSink().saveUnique(snapshot, in: chosen)
        #expect(try Data(contentsOf: resolved.appendingPathComponent("shot.png")) == snapshot.bytes)
        #expect(TestSupport.directoryEntries(resolved) == ["shot.png", unique.lastPathComponent].sorted())
    }

    /// Whether the temporary folder's volume ignores letter case; the case-alias test needs one.
    static let temporaryVolumeIgnoresCase: Bool = {
        guard let root = try? TestSupport.makeTemporaryDirectory() else { return false }
        defer { TestSupport.removeDirectory(root) }
        let folder = root.appendingPathComponent("Probe", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil
        else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("probe").path(percentEncoded: false))
    }()

    // R3-11 (third review of T1a): on a case-sensitive temporary volume the fixture's precondition
    // failed before FileSink ran; the test now runs only where letter case is ignored.
    @Test(
        "A folder spelled with different letter case on a case-insensitive volume is admitted",
        .enabled(if: temporaryVolumeIgnoresCase, "the temporary folder's volume is case-sensitive"))
    func caseVariantFolderIsAdmitted() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(root) }
        let folder = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let variant = root.appendingPathComponent("exports", isDirectory: true)
        try #require(
            FileManager.default.fileExists(atPath: variant.path(percentEncoded: false)),
            "control: this volume is case-sensitive")
        _ = try FileSink().save(snapshot, to: variant.appendingPathComponent("shot.png"), overwrite: false)
        #expect(try Data(contentsOf: folder.appendingPathComponent("shot.png")) == snapshot.bytes)
    }

    // R3-05 (third review of T1a): the save wrote through the admitted folder but returned the URL
    // it was given, so an alias retargeted after admission made the result name another folder.
    @Test("The saved URL names the admitted folder even when the alias is retargeted after resolution")
    func savedURLNamesAdmittedFolder() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(root) }
        let admitted = root.appendingPathComponent("admitted", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: false)
        try FileManager.default.createDirectory(at: admitted, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: admitted)
        var retargeted = false
        let sink = FileSink(
            fileSystem: POSIXFileSystem(afterResolve: { _ in
                retargeted =
                    unlink(alias.path(percentEncoded: false)) == 0
                    && symlink(other.path(percentEncoded: false), alias.path(percentEncoded: false)) == 0
            }))
        let saved = try sink.save(snapshot, to: alias.appendingPathComponent("shot.png"), overwrite: false)
        let unique = try FileSink().saveUnique(snapshot, in: alias)
        try #require(retargeted, "control: the alias was never retargeted")
        #expect(try Data(contentsOf: saved) == snapshot.bytes, "the returned URL does not lead to the saved file")
        #expect(
            saved.resolvingSymlinksInPath().path
                == admitted.appendingPathComponent("shot.png").resolvingSymlinksInPath().path)
        #expect(TestSupport.directoryEntries(other) == [unique.lastPathComponent])
        #expect(!unique.path(percentEncoded: false).contains("/alias/"), "the unique save returned the alias")
    }

    @Test("A folder replaced by another folder while it is admitted is refused and nothing is written")
    func folderReplacedDuringAdmissionIsRefused() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(root) }
        let chosen = root.appendingPathComponent("shots", isDirectory: true)
        let aside = root.appendingPathComponent("aside", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false)
        var replaced = false
        let sink = FileSink(
            fileSystem: POSIXFileSystem(afterResolve: { _ in
                guard !replaced else { return }
                replaced =
                    rename(chosen.path(percentEncoded: false), aside.path(percentEncoded: false)) == 0
                    && mkdir(chosen.path(percentEncoded: false), 0o755) == 0
            }))
        #expect(throws: SinkError.accessDenied) {
            try sink.save(snapshot, to: chosen.appendingPathComponent("shot.png"), overwrite: false)
        }
        try #require(replaced, "control: the folder was never replaced")
        #expect(TestSupport.directoryEntries(chosen).isEmpty)
        #expect(TestSupport.directoryEntries(aside).isEmpty)
    }

    // R03 (adversarial review of T1a): the destination's mode and ACL were read by path, following
    // a link, so they could come from different objects.
    @Test("Overwriting a destination that is a link is refused and the linked file is untouched")
    func overwriteOfLinkIsRefused() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let target = folder.appendingPathComponent("target.png")
        try priorBytes.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let url = folder.appendingPathComponent("shot.png")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(throws: SinkError.accessDenied) { try FileSink().save(snapshot, to: url, overwrite: true) }
        #expect(Self.isSymbolicLink(url), "the link was replaced")
        #expect(try Data(contentsOf: target) == priorBytes)
        #expect(Self.mode(target) == 0o644)
        #expect(throws: SinkError.destinationExists) { try FileSink().save(snapshot, to: url, overwrite: false) }
        #expect(TestSupport.directoryEntries(folder) == ["shot.png", "target.png"])
    }

    // R02 (adversarial review of T1a): the stage sat in the destination folder, where an inherited
    // entry could let another user open it before its final access was set.
    @Test("The stage is written inside a private folder that no inherited entry opens to others")
    func stageFolderIsPrivate() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        try Self.addACL("everyone allow list,add_file,search,read,file_inherit,directory_inherit", to: folder)
        var stageFolder: (mode: mode_t?, acl: String?)?
        let sink = FileSink(
            fileSystem: POSIXFileSystem(afterSync: { stage in
                let parent = stage.deletingLastPathComponent()
                stageFolder = (Self.mode(parent), Self.extendedACL(parent))
            }))
        let saved = try sink.saveUnique(snapshot, in: folder)
        let observed = try #require(stageFolder, "the seam never saw the stage")
        #expect(observed.mode == 0o700)
        #expect(observed.acl == nil, "the stage's folder inherited an entry that lets others in")
        #expect(TestSupport.directoryEntries(folder) == [saved.lastPathComponent])
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

    // N02 (second review of T1a): the overwrite copied the mode but never compared owners. A shared
    // 0644 file of another owner, replaced by this user, would leave that owner in "other" with
    // read access to the screenshot. The owner check uses the `saver` seam, because a test cannot
    // create a file owned by another account.
    @Test("Overwriting a file of another owner makes the replacement owner-only")
    func overwriteOfAnotherOwnersFileIsOwnerOnly() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let sink = FileSink(fileSystem: POSIXFileSystem(saver: geteuid() &+ 1))
        _ = try sink.save(snapshot, to: url, overwrite: true)
        #expect(try Data(contentsOf: url) == snapshot.bytes)
        #expect(Self.mode(url) == 0o600)
        // Control: with the same owner the mode is kept.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        _ = try FileSink().save(snapshot, to: url, overwrite: true)
        #expect(Self.mode(url) == 0o644)
    }

    enum OwnerOnly: String, CaseIterable, Sendable {
        /// Same owner, group that cannot be kept: the owner's own bits stay as they were.
        case sameOwnerReadOnly
        /// Another owner: owner-only for this user.
        case anotherOwner
    }

    // R3-06 (third review of T1a): the owner-only fallback set 0600 even for a same-owner 0400
    // file, adding write access, and kept ACL grants copied from the destination.
    @Test(
        "The owner-only replacement keeps the owner's bits for the same owner and carries no ACL",
        arguments: OwnerOnly.allCases)
    func ownerOnlyReplacementHasNoACL(kind: OwnerOnly) throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer {
            Self.clearACLs(in: folder)
            TestSupport.removeDirectory(folder)
        }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        try Self.addACL("everyone allow read", to: url)
        let fileSystem: POSIXFileSystem
        let expected: mode_t
        switch kind {
        case .sameOwnerReadOnly:
            _ = try #require(
                Self.otherGroup(for: url), "control: this user has no second group to give the destination")
            try FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: url.path)
            fileSystem = POSIXFileSystem(changeGroup: { _, _ in
                errno = EPERM
                return -1
            })
            expected = 0o400
        case .anotherOwner:
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            fileSystem = POSIXFileSystem(saver: geteuid() &+ 1)
            expected = 0o600
        }
        try #require(Self.extendedACL(url) != nil, "control: the destination has no ACL")
        _ = try FileSink(fileSystem: fileSystem).save(snapshot, to: url, overwrite: true)
        #expect(try Data(contentsOf: url) == snapshot.bytes)
        #expect(Self.mode(url) == expected)
        #expect(Self.extendedACL(url) == nil, "the owner-only replacement kept the destination's ACL")
    }

    // R2-D02 (program 2026-11): a new file takes its folder's group, so an overwrite kept the mode
    // of a 0640 file of group A and handed group read access to the folder's group B.
    @Test("Overwriting keeps the replaced file's group, so its group permission reaches no other group")
    func overwriteKeepsGroup() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        let other = try #require(
            Self.otherGroup(for: url), "control: this user has no second group to give the destination")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        _ = try FileSink().save(snapshot, to: url, overwrite: true)
        #expect(try Data(contentsOf: url) == snapshot.bytes)
        #expect(Self.group(url) == other, "the replacement took the folder's group")
        #expect(Self.mode(url) == 0o640)
    }

    @Test("When the replaced file's group cannot be applied, the replacement is owner-only")
    func overwriteWithoutGroupDropsGroupAccess() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        let other = try #require(
            Self.otherGroup(for: url), "control: this user has no second group to give the destination")
        try FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: url.path)
        let observed = Observation()
        let sink = FileSink(
            fileSystem: POSIXFileSystem(changeGroup: { _, group in
                observed.requestedGroups.append(group)
                errno = EPERM
                return -1
            }))
        _ = try sink.save(snapshot, to: url, overwrite: true)
        #expect(observed.requestedGroups == [other], "control: the seam never refused the destination's group")
        #expect(try Data(contentsOf: url) == snapshot.bytes)
        #expect(Self.group(url) != other)
        // R04: dropping only the group bits would move a member of the old group into "other".
        #expect(Self.mode(url) == 0o600, "the replacement is not owner-only without the replaced file's group")
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
        var planted: URL?
        let fileSystem = POSIXFileSystem.interposing { temporary in
            planted = temporary
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
        // R05: the planted link is not Recortia's, so it and the private folder holding it stay.
        let link = try #require(planted)
        var status = stat()
        #expect(lstat(link.path(percentEncoded: false), &status) == 0, "cleanup deleted an entry it did not create")
    }

    // N01 (second review of T1a): a swap that brought back something other than the inspected
    // destination was undone with its result ignored, so a failed undo hid the other file in the
    // private folder while the save reported a plain failure.
    @Test(
        "A destination replaced before the swap is swapped back; a swap back that fails names what it left",
        arguments: [false, true])
    func swapRollback(failing: Bool) throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        defer { chmod(folder.path(percentEncoded: false), 0o755) }
        let url = folder.appendingPathComponent("shot.png")
        let aside = folder.appendingPathComponent("aside.png")
        try priorBytes.write(to: url)
        let theirs = Data("a file that took the name".utf8)
        var steps = 0
        var replaced = false
        var blocked = false
        let fileSystem = POSIXFileSystem(
            afterReplaceStep: { _ in
                steps += 1
                guard steps == 2 else { return }
                replaced =
                    rename(url.path(percentEncoded: false), aside.path(percentEncoded: false)) == 0
                    && (try? theirs.write(to: url)) != nil
            },
            afterSwap: { _ in
                guard failing else { return }
                blocked = chmod(folder.path(percentEncoded: false), 0o555) == 0
            })
        var thrown: SinkError?
        do { _ = try FileSink(fileSystem: fileSystem).save(snapshot, to: url, overwrite: true) } catch {
            thrown = error
        }
        try #require(replaced, "control: the destination was never replaced")
        #expect(try Data(contentsOf: aside) == priorBytes)
        guard failing else {
            #expect(thrown == .accessDenied)
            #expect(try Data(contentsOf: url) == theirs)
            #expect(TestSupport.directoryEntries(folder) == ["aside.png", "shot.png"])
            return
        }
        try #require(blocked, "control: the folder was never made read-only")
        chmod(folder.path(percentEncoded: false), 0o755)
        guard case .leftover(let name) = thrown else {
            Issue.record("expected a leftover failure, got \(String(describing: thrown))")
            return
        }
        #expect(name.hasPrefix(".recortia-") && name.hasSuffix("/stage"), "unexpected leftover \(name)")
        #expect(try Data(contentsOf: folder.appendingPathComponent(name)) == theirs, "the other file was lost")
        // R3-01 (third review of T1a): a later save must never remove what a failed save kept.
        _ = try FileSink().save(snapshot, to: folder.appendingPathComponent("next.png"), overwrite: false)
        #expect(
            try Data(contentsOf: folder.appendingPathComponent(name)) == theirs,
            "a later save deleted the file a failed save kept for recovery")
    }

    // R3-03 (third review of T1a): on a swap-capable mount that ignores ownership, the swap installed
    // the screenshot and cleanup then had to report the displaced original as a leftover, so a
    // correct replacement was reported as failed.
    @Test("An overwrite on a swap-capable volume that ignores ownership succeeds and leaves nothing")
    func overwriteWithoutEnforcedOwnersSucceeds() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        let sink = FileSink(
            fileSystem: POSIXFileSystem(volumeTraits: { _ in
                VolumeTraits(exclusiveRename: true, swap: true, enforcesOwners: false)
            }))
        _ = try sink.save(snapshot, to: url, overwrite: true)
        #expect(try Data(contentsOf: url) == snapshot.bytes)
        #expect(TestSupport.directoryEntries(folder) == ["shot.png"])
    }

    @Test("Overwriting a destination that has a second hard link replaces the name and keeps the other link")
    func hardLinkedDestinationIsReplaced() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        let other = folder.appendingPathComponent("other.png")
        try priorBytes.write(to: url)
        try #require(link(url.path(percentEncoded: false), other.path(percentEncoded: false)) == 0)
        _ = try FileSink().save(snapshot, to: url, overwrite: true)
        #expect(try Data(contentsOf: url) == snapshot.bytes)
        #expect(try Data(contentsOf: other) == priorBytes)
        #expect(TestSupport.directoryEntries(folder) == ["other.png", "shot.png"])
    }

    // R05 (second review of T1a): the empty probe that reads a folder's inherited entries was
    // removed by name after an identity check, so a file that took its name in between was deleted.
    @Test("A file that takes the probe's name is never deleted and the save is refused")
    func substitutedProbeIsKept() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer {
            Self.clearACLs(in: folder)
            TestSupport.removeDirectory(folder)
        }
        try Self.addACL("everyone allow read,file_inherit", to: folder)
        let theirs = Data("a file that took the probe's name".utf8)
        let decoy = folder.appendingPathComponent("theirs.tmp")
        try theirs.write(to: decoy)
        var probe: URL?
        let fileSystem = POSIXFileSystem(afterProbe: { probed in
            if rename(decoy.path(percentEncoded: false), probed.path(percentEncoded: false)) == 0 { probe = probed }
        })
        let url = folder.appendingPathComponent("shot.png")
        #expect(throws: SinkError.accessDenied) {
            try FileSink(fileSystem: fileSystem).save(snapshot, to: url, overwrite: false)
        }
        let probed = try #require(probe, "control: the probe's name was never taken")
        #expect(try Data(contentsOf: probed) == theirs, "a file Recortia did not create was deleted")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A temporary file that gained a second name before the commit is refused")
    func temporaryFileWithSecondNameIsRefused() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        let observed = Observation()
        let fileSystem = POSIXFileSystem.interposing { temporary in
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
        let fileSystem = POSIXFileSystem.interposing { temporary in
            observed.temporaryACL = Self.extendedACL(temporary)
        }
        _ = try FileSink(fileSystem: fileSystem).save(snapshot, to: url, overwrite: true)
        #expect(observed.temporaryACL == nil, "the temporary file carried an inherited entry")
        #expect(try Data(contentsOf: url) == snapshot.bytes)
        #expect(Self.extendedACL(url) == nil, "the replaced private file gained an entry")
        #expect(Self.mode(url) == 0o600)
    }

    // R2-D03 (program 2026-11): an overwrite whose destination was missing staged a new file with
    // the folder's inherited entries; a private destination restored before the commit (a sync
    // client, another app) was then replaced by a file that kept those entries. The stage now has
    // no entries until it is published (R02).
    @Test("A private file that reappears during an overwrite is replaced without the folder's inherited entry")
    func reappearingPrivateDestinationGetsNoInheritedEntry() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        try Self.addACL("everyone allow read,file_inherit", to: folder)
        let url = folder.appendingPathComponent("shot.png")
        let control = try Self.plainFileACL(in: folder)
        try #require(control?.contains("everyone") == true, "control: the folder entry is not inherited")
        let observed = Observation()
        let fileSystem = POSIXFileSystem.interposing { temporary in
            observed.temporaryACL = Self.extendedACL(temporary)
            // The private file comes back: owner-only, with no ACL of its own.
            try? priorBytes.write(to: url)
            if let empty = acl_init(0) {
                observed.destinationACLCleared =
                    acl_set_file(url.path(percentEncoded: false), ACL_TYPE_EXTENDED, empty) == 0
                acl_free(UnsafeMutableRawPointer(empty))
            }
            _ = chmod(url.path(percentEncoded: false), 0o600)
        }
        _ = try FileSink(fileSystem: fileSystem).save(snapshot, to: url, overwrite: true)
        #expect(observed.temporaryACL == nil, "the stage carried the folder's entry before publishing")
        try #require(observed.destinationACLCleared, "control: the restored destination kept an ACL")
        #expect(try Data(contentsOf: url) == snapshot.bytes)
        #expect(Self.extendedACL(url) == nil, "the replaced private file gained the folder's entry")
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

    // Security review of the NV-02 fix: a new file's temporary file was created 0644 and written
    // with its inherited entries removed, inherited deny entries included, so others could read
    // the bytes being written in a folder whose deny entry keeps them out of every finished file.
    @Test(
        "A new file stays owner-only while written and ends with the folder's deny and allow entries and its usual mode",
        arguments: NewSave.allCases)
    func newSaveIsPrivateWhileWritten(kind: NewSave) throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        try Self.addACL("nobody deny read,file_inherit", to: folder)
        try Self.addACL("everyone allow read,file_inherit", to: folder)
        // Control: what the previous creation call, open(2) with 0644, gives a file in this folder.
        let control = try Self.createdWithMode0644(in: folder)
        try #require(
            control.acl?.contains(":deny") == true && control.acl?.contains(":allow") == true,
            "control: the folder's deny and allow entries are not inherited (\(control.acl ?? "nil"))")

        let observed = Observation()
        let sink = FileSink(
            fileSystem: POSIXFileSystem(afterSync: { temporary in
                observed.temporaryMode = Self.mode(temporary)
                observed.temporaryACL = Self.extendedACL(temporary)
            }))
        let url = folder.appendingPathComponent("shot.png")
        let saved =
            switch kind {
            case .save: try sink.save(snapshot, to: url, overwrite: false)
            case .overwriteMissing: try sink.save(snapshot, to: url, overwrite: true)
            case .saveUnique: try sink.saveUnique(snapshot, in: folder)
            }
        let writtenMode = try #require(observed.temporaryMode, "the seam never saw the temporary file")
        #expect(writtenMode == 0o600, "the temporary file was not owner-only while written")
        #expect(writtenMode & 0o077 == 0, "others could read the bytes being written")
        #expect(observed.temporaryACL == nil, "inherited entries were in effect while bytes were written")
        #expect(try Data(contentsOf: saved) == snapshot.bytes)
        #expect(Self.extendedACL(saved) == control.acl, "the new file lost the folder's inherited entries")
        #expect(Self.mode(saved) == control.mode, "the new file's mode changed")
    }

    // NV-06 (final pre-release audit): an overwrite gave the temporary file the destination's mode
    // before its ACL, so a 0644 file kept private by a deny entry had a replacement that was 0644
    // without that entry for an instant: broader than the file it replaces.
    @Test("Overwriting a file kept private by a deny entry never makes the new file broader than it")
    func overwriteIsNeverBroaderThanDestination() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer {
            Self.clearACLs(in: folder)
            TestSupport.removeDirectory(folder)
        }
        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try Self.addACL("nobody deny read", to: url)
        let before = Self.extendedACL(url)
        let denyRead = try Self.denyReadEntry(url)

        let observed = Observation()
        let sink = FileSink(
            fileSystem: POSIXFileSystem(afterReplaceStep: { observed.replaceSteps.append(Self.access($0)) }))
        _ = try sink.save(snapshot, to: url, overwrite: true)
        try #require(
            observed.replaceSteps.contains { $0.acl?.contains(denyRead) == true },
            "control: the seam never saw the deny entry on the temporary file (\(observed.replaceSteps))")
        let exposed = observed.replaceSteps.filter { Self.isBroader($0, without: denyRead) }
        #expect(exposed.isEmpty, "the temporary file was broader than 0600 without the deny entry: \(exposed)")
        #expect(try Data(contentsOf: url) == snapshot.bytes)
        #expect(Self.mode(url) == 0o644)
        #expect(Self.extendedACL(url) == before, "the replaced file lost its deny entry")
    }

    // NV-06: when the rename failed, the copied ACL was cleared while the temporary file still had
    // the destination's broad mode, so the complete new image was briefly broader again.
    @Test("A refused overwrite returns the temporary file to owner-only before clearing its copied entries")
    func refusedOverwriteIsOwnerOnlyWhenEntriesAreCleared() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer {
            Self.clearACLs(in: folder)
            TestSupport.removeDirectory(folder)
        }
        let denyDelete = "\(NSUserName()) deny delete"
        // Control: in this directory the entry really refuses a rename onto the file.
        let control = folder.appendingPathComponent("control.png")
        let replacement = folder.appendingPathComponent("control-new.png")
        try priorBytes.write(to: control)
        try priorBytes.write(to: replacement)
        try Self.addACL(denyDelete, to: control)
        let renameResult = rename(replacement.path(percentEncoded: false), control.path(percentEncoded: false))
        try #require(renameResult != 0, "control: the deny-delete entry did not refuse the rename")
        Self.clearACLs(in: folder)
        try FileManager.default.removeItem(at: control)
        try FileManager.default.removeItem(at: replacement)

        let url = folder.appendingPathComponent("shot.png")
        try priorBytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try Self.addACL("nobody deny read", to: url)
        try Self.addACL(denyDelete, to: url)
        let denyRead = try Self.denyReadEntry(url)

        let observed = Observation()
        let sink = FileSink(
            fileSystem: POSIXFileSystem(afterReplaceStep: { observed.replaceSteps.append(Self.access($0)) }))
        #expect(throws: SinkError.accessDenied) { try sink.save(snapshot, to: url, overwrite: true) }
        let cleared = try #require(observed.replaceSteps.last, "the seam never saw the temporary file")
        try #require(
            observed.replaceSteps.dropLast().contains { $0.acl?.contains(denyRead) == true } && cleared.acl == nil,
            "control: the copied entries were never cleared after the failed rename (\(observed.replaceSteps))")
        #expect(cleared.mode == 0o600, "the copied entries were cleared while the temporary file was broader")
        let exposed = observed.replaceSteps.filter { Self.isBroader($0, without: denyRead) }
        #expect(exposed.isEmpty, "the temporary file was broader than 0600 without the deny entry: \(exposed)")
        #expect(try Data(contentsOf: url) == priorBytes)
        #expect(TestSupport.directoryEntries(folder) == ["shot.png"], "a temporary export was left behind")
    }

    /// The `nobody deny read` line of the file's ACL text; failing means the control entry is missing.
    private static func denyReadEntry(_ url: URL) throws -> String {
        let acl = try #require(extendedACL(url), "control: the destination has no ACL")
        let line = acl.split(separator: "\n").first { $0.contains(":nobody:") && $0.hasSuffix(":deny:read") }
        return String(try #require(line, "control: the destination has no deny-read entry (\(acl))"))
    }

    private static func access(_ url: URL) -> Observation.Access { .init(mode: mode(url), acl: extendedACL(url)) }

    /// Readable beyond the owner by mode while the destination's deny entry is not in effect.
    private static func isBroader(_ access: Observation.Access, without denyRead: String) -> Bool {
        (access.mode ?? 0) & 0o077 != 0 && access.acl?.contains(denyRead) != true
    }

    /// The ACL and mode of an empty file created in `folder` the way temporary files used to be.
    private static func createdWithMode0644(in folder: URL) throws -> (acl: String?, mode: mode_t?) {
        let path = folder.appendingPathComponent("mode-control").path(percentEncoded: false)
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        try #require(descriptor >= 0, "control: could not create the mode control file")
        close(descriptor)
        defer { unlink(path) }
        let url = URL(fileURLWithPath: path)
        return (extendedACL(url), mode(url))
    }

    final class Observation {
        var temporaryMode: mode_t?
        var swapResolvesToVictim = false
        var temporaryACL: String?
        var replaceSteps: [Access] = []
        var requestedGroups: [gid_t] = []
        var destinationACLCleared = false

        struct Access: CustomStringConvertible {
            let mode: mode_t?
            let acl: String?
            var description: String { "(mode \(mode.map { String($0, radix: 8) } ?? "nil"), acl \(acl ?? "nil"))" }
        }
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

    private static func group(_ url: URL) -> gid_t? {
        var status = stat()
        guard lstat(url.path(percentEncoded: false), &status) == 0 else { return nil }
        return status.st_gid
    }

    /// Gives `url` one of this user's groups other than the one it was created with (its folder's)
    /// and returns it; nil when the user has no such group.
    private static func otherGroup(for url: URL) -> gid_t? {
        guard let current = group(url) else { return nil }
        var groups = [gid_t](repeating: 0, count: Int(NGROUPS_MAX))
        let count = getgroups(Int32(groups.count), &groups)
        guard count > 0 else { return nil }
        for candidate in groups.prefix(Int(count)) where candidate != current {
            if chown(url.path(percentEncoded: false), uid_t.max, candidate) == 0 { return candidate }
        }
        return nil
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
