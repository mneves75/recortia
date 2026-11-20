import Foundation
import Testing

@testable import MacPlatform

// People save to exFAT and FAT32 drives. Those volumes have no ACLs, no POSIX owners, no hard
// links and no exclusive rename, and a new file's number changes once it gets its first bytes.
// The tests attach small disk images of their own, without Finder, and always detach them; where
// this environment cannot attach an image at all, the suite is skipped, never passed.
@Suite(
    "File sink on exFAT and FAT32 volumes (FR-07, EXP-02)",
    // Images attached in parallel make hdiutil fail to attach some of them.
    .serialized,
    .enabled(if: ScratchVolume.isAvailable, "hdiutil cannot create and attach a disk image here"))
struct FileSinkVolumeTests {
    let snapshot = TestSupport.snapshot()
    let priorBytes = Data("prior destination".utf8)

    @Test(
        "New, refused, overwriting and unique saves work and leave no temporary file",
        arguments: ScratchVolume.Format.allCases)
    func savePathsWork(format: ScratchVolume.Format) throws {
        try ScratchVolume.withMounted(format) { folder in
            let sink = FileSink()
            let url = folder.appendingPathComponent("shot.png")
            #expect(try sink.save(snapshot, to: url, overwrite: false) == url)
            #expect(try Data(contentsOf: url) == snapshot.bytes)
            #expect(throws: SinkError.destinationExists) { try sink.save(snapshot, to: url, overwrite: false) }
            #expect(try Data(contentsOf: url) == snapshot.bytes)
            try priorBytes.write(to: url)
            #expect(try sink.save(snapshot, to: url, overwrite: true) == url)
            #expect(try Data(contentsOf: url) == snapshot.bytes)
            let first = try sink.saveUnique(snapshot, in: folder)
            let second = try sink.saveUnique(snapshot, in: folder)
            #expect(first != second && first != url && second != url)
            #expect(try Data(contentsOf: second) == snapshot.bytes)
            #expect(TestSupport.directoryEntries(folder) == [url, first, second].map(\.lastPathComponent).sorted())
        }
    }

    // Shape note (second review of T1a): the save wrote and flushed a full stage before it found
    // the volume had no exclusive rename, then wrote the same bytes again into the claim. There
    // the stage's folder has no owners, so that first copy was readable by anyone for no purpose.
    @Test(
        "A new save writes the snapshot straight into the claimed name and never creates a stage",
        arguments: ScratchVolume.Format.allCases, [false, true])
    func newSaveWritesNoStage(format: ScratchVolume.Format, unique: Bool) throws {
        try ScratchVolume.withMounted(format) { folder in
            var claimed = 0
            var staged: [String] = []
            let fileSystem = POSIXFileSystem(afterClaim: { _ in
                claimed += 1
                staged += TestSupport.directoryEntries(folder).filter { $0.hasPrefix(".recortia-") }
            })
            let sink = FileSink(fileSystem: fileSystem)
            let url =
                unique
                ? try sink.saveUnique(snapshot, in: folder)
                : try sink.save(snapshot, to: folder.appendingPathComponent("shot.png"), overwrite: false)
            try #require(claimed == 1, "control: the save did not claim its name")
            #expect(staged.isEmpty, "a stage existed while the claim was written: \(staged)")
            #expect(try Data(contentsOf: url) == snapshot.bytes)
            #expect(TestSupport.directoryEntries(folder) == [url.lastPathComponent])
        }
    }

    // R09 (adversarial review of T1a): a writer with access to the claimed file could change its
    // bytes after Recortia wrote them without changing its size, and the save reported success.
    @Test(
        "A claimed file changed after the snapshot was written into it is reported, not saved, and kept",
        arguments: ScratchVolume.Format.allCases)
    func claimChangedAfterWriteIsNotSaved(format: ScratchVolume.Format) throws {
        try ScratchVolume.withMounted(format) { folder in
            let url = folder.appendingPathComponent("shot.png")
            let tampered = Data(repeating: 0x41, count: snapshot.bytes.count)
            var changed = false
            let fileSystem = POSIXFileSystem(afterClaimWrite: { claimed in
                guard let handle = try? FileHandle(forUpdating: claimed) else { return }
                changed = (try? handle.seek(toOffset: 0)) != nil && (try? handle.write(contentsOf: tampered)) != nil
                try? handle.synchronize()
                try? handle.close()
            })
            #expect(throws: SinkError.writeFailed(code: Int(EIO))) {
                try FileSink(fileSystem: fileSystem).save(snapshot, to: url, overwrite: false)
            }
            try #require(changed, "control: the claimed file was never changed")
            #expect(try Data(contentsOf: url) == tampered, "a file Recortia did not finish was removed or changed")
            #expect(TestSupport.directoryEntries(folder) == ["shot.png"], "a stage was left behind")
        }
    }

    // R09 (second review of T1a): the size was checked only before the read-back, so bytes another
    // writer appended while it ran left the compared prefix equal and the save reported success.
    @Test(
        "A claimed file that grows while it is read back is reported, not saved",
        arguments: ScratchVolume.Format.allCases)
    func claimGrownDuringReadBackFails(format: ScratchVolume.Format) throws {
        try ScratchVolume.withMounted(format) { folder in
            let url = folder.appendingPathComponent("shot.png")
            var grew = false
            let fileSystem = POSIXFileSystem(afterReadBack: { claimed in
                guard let handle = try? FileHandle(forUpdating: claimed) else { return }
                grew = (try? handle.seekToEnd()) != nil && (try? handle.write(contentsOf: Data([0x41]))) != nil
                try? handle.close()
            })
            #expect(throws: SinkError.writeFailed(code: Int(EIO))) {
                try FileSink(fileSystem: fileSystem).save(snapshot, to: url, overwrite: false)
            }
            try #require(grew, "control: the claimed file never grew")
            #expect(FileManager.default.fileExists(atPath: url.path), "a file Recortia did not finish was removed")
        }
    }

    // N05 (second review of T1a): the read-back is compared in fixed chunks; a change past the
    // first chunk must still be seen.
    @Test(
        "A large claimed file changed past its first read-back chunk is reported, not saved",
        arguments: ScratchVolume.Format.allCases)
    func claimChangedPastFirstChunkFails(format: ScratchVolume.Format) throws {
        try ScratchVolume.withMounted(format) { folder in
            let large = TestSupport.snapshot(bytes: Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 * 7) }))
            let url = folder.appendingPathComponent("shot.png")
            var changed = false
            let fileSystem = POSIXFileSystem(afterClaimWrite: { claimed in
                guard let handle = try? FileHandle(forUpdating: claimed) else { return }
                let offset: UInt64 = 150_000
                let original = large.bytes[Int(offset)]
                changed =
                    (try? handle.seek(toOffset: offset)) != nil
                    && (try? handle.write(contentsOf: Data([original ^ 0xFF]))) != nil
                try? handle.synchronize()
                try? handle.close()
            })
            #expect(throws: SinkError.writeFailed(code: Int(EIO))) {
                try FileSink(fileSystem: fileSystem).save(large, to: url, overwrite: false)
            }
            try #require(changed, "control: the claimed file was never changed")
        }
    }

    @Test("A write that makes no progress is an I/O failure, not a hang", arguments: ScratchVolume.Format.allCases)
    func zeroProgressClaimWriteFails(format: ScratchVolume.Format) throws {
        try ScratchVolume.withMounted(format) { folder in
            let fileSystem = POSIXFileSystem(writeBytes: { _, _, _ in 0 })
            #expect(throws: SinkError.writeFailed(code: Int(EIO))) {
                try FileSink(fileSystem: fileSystem).save(
                    snapshot, to: folder.appendingPathComponent("shot.png"), overwrite: false)
            }
        }
    }

    // Security review of 855447f: an overwrite there falls back to a plain rename, and the
    // stage's private folder has no owners or modes on these volumes, so another user could
    // change the staged bytes before the rename and the save reported success.
    @Test(
        "An overwrite whose staged bytes changed before the rename is reported as failed",
        arguments: ScratchVolume.Format.allCases)
    func overwriteWithChangedStageFails(format: ScratchVolume.Format) throws {
        try ScratchVolume.withMounted(format) { folder in
            let url = folder.appendingPathComponent("shot.png")
            try priorBytes.write(to: url)
            let tampered = Data(repeating: 0x41, count: snapshot.bytes.count)
            var changed = false
            let fileSystem = POSIXFileSystem.interposing { stage in
                guard let handle = try? FileHandle(forUpdating: stage) else { return }
                changed = (try? handle.seek(toOffset: 0)) != nil && (try? handle.write(contentsOf: tampered)) != nil
                try? handle.synchronize()
                try? handle.close()
            }
            #expect(throws: SinkError.writeFailed(code: Int(EIO))) {
                try FileSink(fileSystem: fileSystem).save(snapshot, to: url, overwrite: true)
            }
            try #require(changed, "control: the staged bytes were never changed")
            // The published file may be someone else's bytes now: it is reported, not deleted.
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(try Data(contentsOf: url) != snapshot.bytes)
        }
    }

    // Automated review of 1a395cb: after the overwrite's plain rename, the read-back went through
    // the stage's descriptor only, so a file another writer renamed over the published name was
    // never noticed and the save reported success for a name holding someone else's bytes.
    @Test(
        "An overwrite whose published name is replaced right after the rename fails and keeps the other file",
        arguments: ScratchVolume.Format.allCases)
    func overwriteReplacedAfterRenameFails(format: ScratchVolume.Format) throws {
        try ScratchVolume.withMounted(format) { folder in
            let url = folder.appendingPathComponent("shot.png")
            try priorBytes.write(to: url)
            let theirs = Data("another writer's bytes".utf8)
            let decoy = folder.appendingPathComponent("theirs.tmp")
            try theirs.write(to: decoy)
            var replaced = false
            let fileSystem = POSIXFileSystem(afterPublish: { published in
                replaced = rename(decoy.path(percentEncoded: false), published.path(percentEncoded: false)) == 0
            })
            #expect(throws: SinkError.destinationExists) {
                try FileSink(fileSystem: fileSystem).save(snapshot, to: url, overwrite: true)
            }
            try #require(replaced, "control: the published name was never replaced")
            #expect(try Data(contentsOf: url) == theirs, "the other writer's file was removed or changed")
        }
    }

    enum ConcurrentWrite: String, CaseIterable, Sendable {
        /// Another writer renames its own file over the claimed name.
        case replacesClaim
        /// Another writer opens the claimed, still empty file and writes into it.
        case writesIntoClaim
    }

    // R2-D04 (program 2026-11): without exclusive rename, the claimed name was renamed over, so
    // bytes another writer put there between the claim and the commit were destroyed by a save
    // that must never overwrite.
    @Test(
        "A file written to the claimed name between the claim and the commit is never destroyed",
        arguments: ScratchVolume.Format.allCases, ConcurrentWrite.allCases)
    func concurrentWriteAfterClaimSurvives(format: ScratchVolume.Format, write: ConcurrentWrite) throws {
        try ScratchVolume.withMounted(format) { folder in
            let url = folder.appendingPathComponent("shot.png")
            let theirs = Data("another writer's bytes".utf8)
            let decoy = folder.appendingPathComponent("theirs.tmp")
            try theirs.write(to: decoy)
            var wrote = false
            let fileSystem = POSIXFileSystem(afterClaim: { claimed in
                switch write {
                case .replacesClaim:
                    wrote = rename(decoy.path(percentEncoded: false), claimed.path(percentEncoded: false)) == 0
                case .writesIntoClaim:
                    guard let handle = try? FileHandle(forWritingTo: claimed) else { return }
                    wrote = (try? handle.write(contentsOf: theirs)) != nil
                    try? handle.close()
                }
            })
            #expect(throws: SinkError.destinationExists) {
                try FileSink(fileSystem: fileSystem).save(snapshot, to: url, overwrite: false)
            }
            try #require(wrote, "control: the other writer never reached the claimed name")
            #expect(try Data(contentsOf: url) == theirs, "the other writer's bytes were destroyed")
            let left = TestSupport.directoryEntries(folder).filter { $0.hasPrefix(".recortia-") }
            #expect(left.isEmpty, "a temporary export was left behind: \(left)")
        }
    }

    @Test(
        "A temporary file replaced by another file before the commit is still refused",
        arguments: ScratchVolume.Format.allCases)
    func substitutedTemporaryFileIsRefused(format: ScratchVolume.Format) throws {
        try ScratchVolume.withMounted(format) { folder in
            let url = folder.appendingPathComponent("shot.png")
            try priorBytes.write(to: url)
            let decoy = folder.appendingPathComponent("decoy.txt")
            try Data("another file".utf8).write(to: decoy)
            var substituted = false
            let fileSystem = POSIXFileSystem.interposing { temporary in
                // Another account renames its own file over the temporary name.
                substituted =
                    rename(decoy.path(percentEncoded: false), temporary.path(percentEncoded: false)) == 0
            }
            #expect(throws: SinkError.accessDenied) {
                try FileSink(fileSystem: fileSystem).save(snapshot, to: url, overwrite: true)
            }
            try #require(substituted, "control: the decoy did not replace the temporary file")
            #expect(try Data(contentsOf: url) == priorBytes)
        }
    }
}

/// A small disk image attached without Finder at a private mount point.
enum ScratchVolume {
    enum Format: String, CaseIterable, Sendable {
        case exFAT, fat32

        /// The file-system type `statfs` reports for a mounted volume of this format.
        var typeName: String {
            switch self {
            case .exFAT: "exfat"
            case .fat32: "msdos"
            }
        }

        var createArguments: [String] {
            switch self {
            case .exFAT: ["-size", "8m", "-fs", "ExFAT"]
            case .fat32: ["-size", "40m", "-fs", "MS-DOS FAT32"]
            }
        }
    }

    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    /// Whether this environment can create, attach and detach an image; checked once per run.
    static let isAvailable: Bool = (try? withMounted(.exFAT) { _ in }) != nil

    /// Runs `body` with an empty folder on a fresh `format` volume, detaching and deleting the
    /// image on every exit path.
    static func withMounted(_ format: Format, _ body: (URL) throws -> Void) throws {
        let work = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(work) }
        let image = work.appendingPathComponent("volume.sparseimage").path(percentEncoded: false)
        let mountPoint = work.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false)
        let mountPath = mountPoint.path(percentEncoded: false)
        // FAT volume names hold at most 11 characters; exFAT refuses a longer one.
        guard hdiutil(["create", "-quiet", "-type", "SPARSE", "-volname", "RTEST"] + format.createArguments + [image])
        else { throw Unavailable(description: "hdiutil could not create a \(format.rawValue) image") }
        guard hdiutil(["attach", "-quiet", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mountPath, image])
        else { throw Unavailable(description: "hdiutil could not attach a \(format.rawValue) image") }
        defer {
            if !hdiutil(["detach", "-quiet", mountPath]) { _ = hdiutil(["detach", "-quiet", "-force", mountPath]) }
        }
        let folder = mountPoint.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        // Control: a folder that is not on the intended volume type would prove nothing.
        let mounted = fileSystemType(of: folder)
        guard mounted == format.typeName else {
            throw Unavailable(description: "the folder is on \(mounted ?? "nothing"), not \(format.typeName)")
        }
        try body(folder)
    }

    private static func fileSystemType(of url: URL) -> String? {
        var info = statfs()
        guard statfs(url.path(percentEncoded: false), &info) == 0 else { return nil }
        return withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func hdiutil(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
