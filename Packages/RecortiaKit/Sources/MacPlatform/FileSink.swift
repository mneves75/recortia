import Darwin
import Domain
import Foundation

// Threat model (program 2026-11, T1a security review). In scope: another user, or a process
// without the person's access, that can write to the chosen destination folder (a shared or
// group-writable folder, a FAT volume). Out of scope: a process running as the same user, which
// can already read everything the user can.
//
// Contract by volume class (decisions.md, "File-save guarantees by volume class"):
// - Volumes that enforce owners and modes (APFS, HFS+) get the full guarantee: a save never
//   publishes bytes other than the sanitized snapshot, never publishes with permissions wider than
//   the destination's, never follows a symbolic link, and never deletes a file it did not create.
// - Volumes without enforced owners (exFAT, FAT32, some shares) get integrity only: no links,
//   nothing deleted that Recortia did not create, a new file written directly into an exclusively
//   created name, and a read-back before success. There is no confidentiality promise there.
// - Replace authorizes the file at that name at save time.
//
// The folder is admitted by identity and bound once as a descriptor; every create, metadata read,
// publish and removal is relative to it. The volume's capabilities choose the path before anything
// is written. With exclusive rename, the bytes are staged in a private folder (0700, no ACL, locked)
// created inside it; the stage gets its final access just before one rename publishes it, after
// its identity is checked. Without it, a new file is written straight into an exclusive claim. An
// entry is removed only from the private folder: it is moved there by exclusive rename, checked,
// and removed if it is Recortia's, or moved back; whatever cannot be moved back, and anything a
// failed save leaves where there is no exclusive rename, is reported by name, never deleted.
//
// Known limits, declined in review:
// - R03: replacing a file on a volume without swap is a plain rename, which replaces whatever
//   occupies the name at that moment. Acceptable under the contract: those volumes enforce no
//   owners, and the name is checked to lead to the stage before and after the read-back.
// - R06: a folder above the chosen one swapped before admission redirects the save; admission
//   binds whatever folder the system resolves the path to at that moment.
// - R01/R02: on a mount that accepts chmod without enforcing it, the private folder is not
//   private; such mounts are covered by the no-confidentiality class above.
// - Replace binds to the name at save time, not to the inode the person saw in the save panel.
// - The empty private folder is removed with rmdir by name after an identity check, and the umask
//   probe in this user's temporary folder by name; rmdir removes only an empty folder.

public struct FileSink {
    private let fileSystem: POSIXFileSystem

    /// Upper bound on collision attempts in `saveUnique`, so a hostile folder cannot spin forever.
    static let maxUniqueAttempts = 1_000

    public init() {
        self.init(fileSystem: POSIXFileSystem())
    }

    init(fileSystem: POSIXFileSystem) {
        self.fileSystem = fileSystem
    }

    /// Writes the snapshot to a user-selected `url` (FR-07, EXP-02). Without `overwrite`, an
    /// existing destination is refused, including one created concurrently. On any failure the
    /// previous destination is untouched and the staged bytes are removed.
    public func save(_ snapshot: ShareSnapshot, to url: URL, overwrite: Bool) throws(SinkError) -> URL {
        let name = url.lastPathComponent
        guard url.isFileURL, !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw .writeFailed(code: Int(EINVAL))
        }
        do {
            _ = try fileSystem.save(
                snapshot.bytes, in: url.deletingLastPathComponent(), names: [name], overwrite: overwrite)
        } catch { throw Self.map(error) }
        return url
    }

    /// Saves under the snapshot's sanitized suggested name in an authorized `folder`, adding
    /// " (n)" before the extension until the name is free. Never overwrites.
    public func saveUnique(_ snapshot: ShareSnapshot, in folder: URL) throws(SinkError) -> URL {
        guard folder.isFileURL else { throw .writeFailed(code: Int(EINVAL)) }
        let name = SafeFilename.sanitize(snapshot.suggestedFilename, fallbackExtension: snapshot.format.fileExtension)
        let names = (1...Self.maxUniqueAttempts).map { ExportFilename.deduplicated(name, attempt: $0) }
        do {
            let saved = try fileSystem.save(snapshot.bytes, in: folder, names: names, overwrite: false)
            return folder.appendingPathComponent(saved, isDirectory: false)
        } catch { throw Self.map(error) }
    }

    static func map(_ failure: FileSystemFailure) -> SinkError {
        if let leftover = failure.leftover { return .leftover(name: leftover) }
        return switch failure.code {
        case ENOSPC, EDQUOT: .diskFull
        case EACCES, EPERM, EROFS: .accessDenied
        case ENOENT, ENXIO, ENODEV: .volumeUnavailable
        case EEXIST: .destinationExists
        default: .writeFailed(code: Int(failure.code))
        }
    }
}

// MARK: - File system

struct FileSystemFailure: Error, Equatable, Sendable {
    let code: Int32
    /// What a failed save left in the folder, relative to it, because removing it could have
    /// removed something Recortia did not create.
    var leftover: String?
}

/// A file or folder by device and inode, so a check reaches the object and not whatever its name
/// now leads to.
struct FileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
    }
}

/// What the folder's volume can do, read before anything is written. A volume that cannot report
/// its capabilities is treated as having none, which selects the direct-write path.
struct VolumeTraits {
    let exclusiveRename: Bool
    let swap: Bool
    /// Whether the volume enforces file owners and modes, so a private folder's entries can be
    /// changed by its owner only. exFAT, FAT32 and some network volumes do not.
    let enforcesOwners: Bool

    init(_ directory: Int32) {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        // A 4-byte length, then the capabilities.
        var buffer = [UInt8](repeating: 0, count: 4 + MemoryLayout<vol_capabilities_attr_t>.size)
        var capabilities: vol_capabilities_attr_t?
        if fgetattrlist(directory, &list, &buffer, buffer.count, 0) == 0 {
            capabilities = buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 4, as: vol_capabilities_attr_t.self)
            }
        }
        func has(_ bit: Int32) -> Bool {
            guard let capabilities else { return false }
            let mask = UInt32(bit)
            // Index 1 is VOL_CAPABILITIES_INTERFACES.
            return capabilities.valid.1 & mask != 0 && capabilities.capabilities.1 & mask != 0
        }
        exclusiveRename = has(VOL_CAP_INT_RENAME_EXCL)
        swap = has(VOL_CAP_INT_RENAME_SWAP)
        var info = statfs()
        enforcesOwners = fstatfs(directory, &info) == 0 && info.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0
    }
}

/// The POSIX operations behind `FileSink`, reporting error codes so failures map precisely. The
/// closures and injected codes are test seams; the app uses the defaults.
struct POSIXFileSystem {
    /// Reported when a name no longer leads to the object Recortia holds, or leads to a link.
    static let substitutedFailure = FileSystemFailure(code: EPERM)
    /// The stage's name inside its private folder.
    static let stageName = "stage"

    /// Runs once the folder's identity is read and its spelling resolved, before it is opened.
    var afterResolve: (URL) -> Void = { _ in }
    /// Runs once the stage's bytes are on disk, while it is still owner-only and without an ACL.
    var afterSync: (URL) -> Void = { _ in }
    /// Runs before the destination is examined and the stage is published.
    var beforePublish: (URL) -> Void = { _ in }
    /// Runs after each change an overwrite makes to the stage's mode or ACL.
    var afterReplaceStep: (URL) -> Void = { _ in }
    /// The account saving, compared with an overwritten file's owner.
    var saver: uid_t = geteuid()
    /// Gives the open stage a group, returning 0 or -1 with `errno` like fchown(2).
    var changeGroup: (Int32, gid_t) -> Int32 = { fchown($0, uid_t.max, $1) }
    /// Runs right after an overwrite swapped the stage with the destination.
    var afterSwap: (URL) -> Void = { _ in }
    /// Runs once the probe that reads a folder's inherited entries exists, before it is discarded.
    var afterProbe: (URL) -> Void = { _ in }
    /// Runs right after an overwrite without swap renamed the stage onto the destination name.
    var afterPublish: (URL) -> Void = { _ in }
    /// Runs once a volume without exclusive rename has claimed the destination name.
    var afterClaim: (URL) -> Void = { _ in }
    /// Runs once the snapshot is written into such a claimed file, before it is flushed.
    var afterClaimWrite: (URL) -> Void = { _ in }
    /// Runs once a claimed file has been read back, before its size is checked again.
    var afterReadBack: (URL) -> Void = { _ in }
    /// Writes bytes like write(2); every write of the snapshot goes through it.
    var writeBytes: @Sendable (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
    /// Fails the stage's write with this code after its first bytes.
    var failWrite: Int32?
    /// Fails the publishing rename with this code.
    var failPublish: Int32?

    /// Writes `data` under the first of `names` that it can take in `folder`, or replaces
    /// `names[0]` when `overwrite` allows, and returns the name used. Without `overwrite`, a taken
    /// name moves on to the next; when none is left the save fails with EEXIST.
    func save(_ data: Data, in folder: URL, names: [String], overwrite: Bool) throws(FileSystemFailure) -> String {
        let directory = try openFolder(folder)
        defer { close(directory) }
        // The publication path is chosen before anything is written.
        let volume = VolumeTraits(directory)
        guard volume.exclusiveRename else {
            return try saveWithoutExclusiveRename(
                data, in: directory, folder: folder, names: names, overwrite: overwrite, volume: volume)
        }
        return try withStage(data, in: directory, folder: folder, volume: volume) { stage throws(FileSystemFailure) in
            for name in names {
                do throws(FileSystemFailure) {
                    try publish(stage, data: data, as: name, in: directory, overwrite: overwrite, volume: volume)
                    return name
                } catch  where error.code == EEXIST && error.leftover == nil && !overwrite {
                    continue
                }
            }
            throw FileSystemFailure(code: EEXIST)
        }
    }

    /// Runs `body` with a new stage of `data`, then removes the stage; anything the removal had to
    /// leave is reported in place of the result.
    private func withStage(
        _ data: Data, in directory: Int32, folder: URL, volume: VolumeTraits,
        _ body: (Stage) throws(FileSystemFailure) -> String
    ) throws(FileSystemFailure) -> String {
        let stage = try Stage(
            in: directory, folder: folder, data: data, privateNamespace: volume.enforcesOwners, fileSystem: self)
        stage.sweepLeftovers()
        beforePublish(stage.url)
        let result: Result<String, FileSystemFailure>
        do { result = .success(try body(stage)) } catch { result = .failure(error) }
        let leftover = stage.remove()
        if case .failure(let failure) = result, failure.leftover != nil { throw failure }
        if let leftover {
            throw FileSystemFailure(code: EIO, leftover: leftover)
        }
        return try result.get()
    }

    /// exFAT, FAT32 and some network volumes: a new file is written straight into an exclusively
    /// created name, with no stage at all; only replacing an existing file stages the bytes.
    private func saveWithoutExclusiveRename(
        _ data: Data, in directory: Int32, folder: URL, names: [String], overwrite: Bool, volume: VolumeTraits
    ) throws(FileSystemFailure) -> String {
        for name in names {
            var existing = stat()
            if fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                guard overwrite else { continue }
                guard existing.st_mode & S_IFMT == S_IFREG else { throw Self.substitutedFailure }
                return try withStage(data, in: directory, folder: folder, volume: volume) {
                    stage throws(FileSystemFailure) in
                    try replace(stage, data: data, named: name, in: directory, volume: volume)
                    return name
                }
            }
            guard errno == ENOENT else { throw FileSystemFailure(code: errno) }
            do {
                try claimThenWrite(data, as: name, in: directory, folder: folder)
                return name
            } catch  where error.code == EEXIST && error.leftover == nil && !overwrite {
                continue
            }
        }
        throw FileSystemFailure(code: EEXIST)
    }

    // MARK: Folder

    /// The approved folder as a descriptor, admitted by identity rather than spelling: the system
    /// resolves the path (links, letter case, Unicode form) to a folder, and the descriptor opened
    /// at that resolved path, without following a final link, must be that same folder. A folder
    /// replaced in between is refused.
    func openFolder(_ url: URL) throws(FileSystemFailure) -> Int32 {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        var expected = stat()
        guard stat(path, &expected) == 0 else { throw FileSystemFailure(code: errno) }
        guard expected.st_mode & S_IFMT == S_IFDIR else { throw Self.substitutedFailure }
        guard let resolved = realpath(path, nil) else { throw FileSystemFailure(code: errno) }
        defer { free(resolved) }
        afterResolve(url)
        let directory = open(resolved, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            throw errno == ELOOP || errno == ENOTDIR ? Self.substitutedFailure : FileSystemFailure(code: errno)
        }
        var actual = stat()
        guard fstat(directory, &actual) == 0, FileIdentity(actual) == FileIdentity(expected) else {
            close(directory)
            throw Self.substitutedFailure
        }
        return directory
    }

    // MARK: Publishing

    private func publish(
        _ stage: Stage, data: Data, as name: String, in directory: Int32, overwrite: Bool, volume: VolumeTraits
    ) throws(FileSystemFailure) {
        var existing = stat()
        if fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard overwrite else { throw FileSystemFailure(code: EEXIST) }
            // Never through a link, and never over a folder or a device.
            guard existing.st_mode & S_IFMT == S_IFREG else { throw Self.substitutedFailure }
            try replace(stage, data: data, named: name, in: directory, volume: volume)
            return
        }
        guard errno == ENOENT else { throw FileSystemFailure(code: errno) }
        try stage.giveNewFileAccess(in: directory, afterProbe: afterProbe)
        try stage.checkStillStaged()
        if let failPublish { throw FileSystemFailure(code: failPublish) }
        guard renameatx_np(stage.folder, Self.stageName, directory, name, UInt32(RENAME_EXCL)) == 0 else {
            throw FileSystemFailure(code: errno)
        }
    }

    /// Gives the stage the destination's ACL, group and mode, all read from one descriptor that
    /// does not follow a link, then swaps it in. The swapped-out entry is removed only while it is
    /// that same destination; otherwise the swap is undone.
    private func replace(
        _ stage: Stage, data: Data, named name: String, in directory: Int32, volume: VolumeTraits
    ) throws(FileSystemFailure) {
        let destination = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard destination >= 0 else {
            throw errno == ELOOP ? Self.substitutedFailure : FileSystemFailure(code: errno)
        }
        // Read-only and used for metadata only: closing it cannot lose data.
        defer { close(destination) }
        var existing = stat()
        guard fstat(destination, &existing) == 0 else { throw FileSystemFailure(code: errno) }
        guard existing.st_mode & S_IFMT == S_IFREG else { throw Self.substitutedFailure }
        let replaced = FileIdentity(existing)
        // ACL first, so a deny entry is in effect before the mode can widen access.
        let copiedACL = try Self.copyACL(from: destination, to: stage.file)
        afterReplaceStep(stage.url)
        var mode = existing.st_mode & 0o777
        var written = stat()
        guard fstat(stage.file, &written) == 0 else { throw FileSystemFailure(code: errno) }
        // Another owner, or a group that cannot be kept, leaves the file owner-only (0600): the
        // replacement belongs to this user, so the old owner, or a member of the old group, would
        // otherwise fall into the "other" class and gain its access.
        if existing.st_uid != saver
            || (written.st_gid != existing.st_gid && changeGroup(stage.file, existing.st_gid) != 0)
        {
            mode = 0o600
        }
        // Best effort: a volume that refuses chmod keeps the owner-only staging mode.
        _ = fchmod(stage.file, mode)
        afterReplaceStep(stage.url)
        do throws(FileSystemFailure) {
            try stage.checkStillStaged()
            if let failPublish { throw FileSystemFailure(code: failPublish) }
            try swap(stage, data: data, with: name, in: directory, replacing: replaced, volume: volume)
        } catch {
            // The copied ACL can deny this user deleting the stage (an entry that denies delete
            // is also why the rename failed); drop it so cleanup works. Owner-only first, so
            // dropping a deny entry never widens access. A stage already published (the read-back
            // after a plain rename failed) is left as published.
            if copiedACL, (try? stage.checkStillStaged()) != nil {
                _ = fchmod(stage.file, 0o600)
                afterReplaceStep(stage.url)
                try? Self.clearACL(stage.file)
                afterReplaceStep(stage.url)
            }
            throw error
        }
    }

    private func swap(
        _ stage: Stage, data: Data, with name: String, in directory: Int32, replacing replaced: FileIdentity,
        volume: VolumeTraits
    ) throws(FileSystemFailure) {
        if volume.swap {
            guard renameatx_np(stage.folder, Self.stageName, directory, name, UInt32(RENAME_SWAP)) == 0 else {
                throw FileSystemFailure(code: errno)
            }
            afterSwap(directoryURL(stage).appendingPathComponent(name, isDirectory: false))
            // The private folder now holds what was at `name`. When that is the inspected
            // destination (any number of links), it is removed as the overwrite the person approved;
            // Replace authorizes the file at that name at save time.
            var swapped = stat()
            if fstatat(stage.folder, Self.stageName, &swapped, AT_SYMLINK_NOFOLLOW) == 0,
                swapped.st_mode & S_IFMT == S_IFREG, FileIdentity(swapped) == replaced
            {
                try stage.removeOwnEntry(Self.stageName)
                return
            }
            // Something replaced the destination after its access was read: put it back, by swap,
            // or by exclusive rename if the name is gone; otherwise report where it is.
            if renameatx_np(stage.folder, Self.stageName, directory, name, UInt32(RENAME_SWAP)) == 0 {
                throw Self.substitutedFailure
            }
            if errno == ENOENT,
                renameatx_np(stage.folder, Self.stageName, directory, name, UInt32(RENAME_EXCL)) == 0
            {
                throw Self.substitutedFailure
            }
            throw stage.hold(Self.stageName)
        }
        // Volumes without swap (exFAT, FAT32, some network volumes) replace by plain rename; the
        // destination may change between reading its access and this rename there.
        try stage.checkStillStaged()
        if renameat(stage.folder, Self.stageName, directory, name) != 0 { throw FileSystemFailure(code: errno) }
        afterPublish(directoryURL(stage).appendingPathComponent(name, isDirectory: false))
        // On exFAT and FAT32 the private folder has no owners or modes, so another user could change
        // the staged bytes before the rename. Read the published file back through the stage's own
        // descriptor (the same file), while the name leads to it before and after; on a mismatch the
        // save failed, and whatever is at the name stays, as it may now hold someone else's bytes.
        try Self.requirePublished(stage.file, as: name, in: directory)
        guard Self.readBack(stage.file, equals: data) else { throw FileSystemFailure(code: EIO, leftover: name) }
        try Self.requirePublished(stage.file, as: name, in: directory)
    }

    private func directoryURL(_ stage: Stage) -> URL {
        stage.url.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Fails with EEXIST unless `name` still leads, without following a link, to the open file as
    /// its only name.
    private static func requirePublished(_ file: Int32, as name: String, in directory: Int32)
        throws(FileSystemFailure)
    {
        var status = stat()
        guard fstat(file, &status) == 0 else { throw FileSystemFailure(code: errno) }
        guard entry(name, in: directory, is: FileIdentity(status), type: S_IFREG) else {
            throw FileSystemFailure(code: EEXIST)
        }
    }

    /// A new file where the volume has no exclusive rename: an exclusive create claims `name` and
    /// the snapshot buffer is appended to that claimed file through its descriptor, so no rename
    /// can replace a file another writer puts there. Success only if, once on disk, the file read
    /// back through the descriptor is exactly `data` and the name still leads to it. A claim that
    /// was not empty when writing began, or that the name no longer leads to, is EEXIST and left
    /// alone. Any other failure leaves the claim and names it: without exclusive rename it cannot
    /// be moved aside to be checked, so removing it by name could remove another writer's file.
    private func claimThenWrite(_ data: Data, as name: String, in directory: Int32, folder: URL)
        throws(FileSystemFailure)
    {
        let mode = try Self.newFileMode()
        let claim = openat(directory, name, O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard claim >= 0 else { throw FileSystemFailure(code: errno) }
        let claimed = folder.appendingPathComponent(name, isDirectory: false)
        afterClaim(claimed)
        var failure: Int32?
        var foreign = false
        var status = stat()
        if fstat(claim, &status) != 0 {
            failure = errno
        } else if status.st_size != 0 {
            failure = EEXIST
            foreign = true
        }
        if failure == nil {
            var written = 0
            failure = Self.writeAll(data, to: claim, written: &written, using: writeBytes)
        }
        if failure == nil { afterClaimWrite(claimed) }
        // Best effort: these volumes keep a mount-wide mode anyway.
        if failure == nil { _ = fchmod(claim, mode) }
        if failure == nil, fsync(claim) != 0 { failure = errno }
        if failure == nil, !Self.readBack(claim, equals: data, afterRead: { afterReadBack(claimed) }) {
            failure = EIO
        }
        let named =
            fstat(claim, &status) == 0 && Self.entry(name, in: directory, is: FileIdentity(status), type: S_IFREG)
        if !named {
            failure = EEXIST
            foreign = true
        }
        if close(claim) != 0, failure == nil { failure = errno }
        guard let failure else { return }
        throw foreign ? FileSystemFailure(code: EEXIST) : FileSystemFailure(code: failure, leftover: name)
    }

    // MARK: Helpers

    /// Whether `name` in `directory` is, without following a link, the object `identity` names,
    /// of `type`, and (for a file) its only name.
    static func entry(_ name: String, in directory: Int32, is identity: FileIdentity, type: mode_t) -> Bool {
        var status = stat()
        guard fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        return status.st_mode & S_IFMT == type && FileIdentity(status) == identity
            && (type != S_IFREG || status.st_nlink == 1)
    }

    /// Bytes compared per read during a read-back, so verifying never holds a second full copy.
    static let readBackChunk = 64 * 1024

    /// Whether the file open as `descriptor` holds exactly `data`: its size before, its bytes
    /// compared chunk by chunk, then its size again after `afterRead`, so bytes appended while it
    /// is read are seen.
    private static func readBack(_ descriptor: Int32, equals data: Data, afterRead: () -> Void = {}) -> Bool {
        guard size(of: descriptor) == off_t(data.count) else { return false }
        var buffer = [UInt8](repeating: 0, count: min(readBackChunk, max(data.count, 1)))
        let matches = data.withUnsafeBytes { expected -> Bool in
            guard let base = expected.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < data.count {
                let wanted = min(buffer.count, data.count - offset)
                // Invariant: each read stays within `buffer`, and each compare within both buffers.
                let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, wanted, off_t(offset)) }
                if count < 0, errno == EINTR { continue }
                guard count > 0, memcmp(buffer, base + offset, count) == 0 else { return false }
                offset += count
            }
            return true
        }
        guard matches else { return false }
        afterRead()
        return size(of: descriptor) == off_t(data.count)
    }

    private static func size(of descriptor: Int32) -> off_t? {
        var status = stat()
        return fstat(descriptor, &status) == 0 ? status.st_size : nil
    }

    /// Writes all of `data` (or its first `failAfter` bytes), retrying interrupted writes and
    /// counting each successful one in `written` at once. Returns the first other write(2) error
    /// code, or nil once everything asked for is written.
    static func writeAll(
        _ data: Data, to descriptor: Int32, written: inout Int, failAfter: Int? = nil,
        using write: (Int32, UnsafeRawPointer, Int) -> Int
    ) -> Int32? {
        // Invariant: `buffer` is valid only inside the closure; every access stays within
        // `buffer.count` because `written` only advances by what write(2) reports it wrote.
        data.withUnsafeBytes { buffer -> Int32? in
            guard let base = buffer.baseAddress else { return nil }
            let end = min(buffer.count, failAfter ?? buffer.count)
            while written < end {
                let result = write(descriptor, base + written, end - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                // No progress would repeat forever.
                if result == 0 { return EIO }
                written += result
            }
            return nil
        }
    }

    /// The mode open(2) gives a file requested as 0644 under the current umask, which is the mode
    /// a new save gets. Reading the umask needs macOS 27 or a process-wide change that other
    /// threads would see, so an empty probe file is created and removed in this user's temporary
    /// folder instead.
    static func newFileMode() throws(FileSystemFailure) -> mode_t {
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent(
            ".recortia-mode-\(UUID().uuidString)", isDirectory: false
        ).path(percentEncoded: false)
        let descriptor = open(probe, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw FileSystemFailure(code: errno) }
        Darwin.unlink(probe)
        var status = stat()
        let result = fstat(descriptor, &status)
        let failure = errno
        close(descriptor)
        guard result == 0 else { throw FileSystemFailure(code: failure) }
        return status.st_mode & 0o777
    }

    /// Gives `target` the ACL of the open `source`. Returns whether an ACL was applied; a source
    /// without one leaves `target` as it is.
    static func copyACL(from source: Int32, to target: Int32) throws(FileSystemFailure) -> Bool {
        guard let acl = acl_get_fd_np(source, ACL_TYPE_EXTENDED) else {
            // ENOENT: the file has no ACL; ENOTSUP: the volume has no ACLs at all.
            if errno == ENOENT || errno == ENOTSUP { return false }
            throw FileSystemFailure(code: errno)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        if acl_set_fd_np(target, acl, ACL_TYPE_EXTENDED) != 0 { throw FileSystemFailure(code: errno) }
        return true
    }

    /// Removes every ACL entry of the open file or folder; a volume without ACLs has none.
    static func clearACL(_ descriptor: Int32) throws(FileSystemFailure) {
        guard let empty = acl_init(0) else { throw FileSystemFailure(code: errno) }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        if acl_set_fd_np(descriptor, empty, ACL_TYPE_EXTENDED) != 0, errno != ENOTSUP {
            throw FileSystemFailure(code: errno)
        }
    }
}

/// The staged bytes: a file in a private folder created inside the destination folder. Only its
/// creator can enter that folder, so no other user can read, replace or link the stage. Where the
/// volume enforces owners (`privateNamespace`), only this user can change the folder's entries, so
/// an entry checked there is the entry removed; elsewhere nothing in it is ever removed by name.
final class Stage {
    /// The destination folder, the private folder inside it and the staged file, all open.
    let directory: Int32
    let folder: Int32
    let file: Int32
    let folderName: String
    let folderIdentity: FileIdentity
    let privateNamespace: Bool
    private(set) var fileIdentity: FileIdentity
    /// Whether the folder holds an entry that is not Recortia's, so it must stay.
    private var holdsForeignEntry = false
    /// The stage's path, for test seams only.
    let url: URL

    init(
        in directory: Int32, folder destination: URL, data: Data, privateNamespace: Bool,
        fileSystem: POSIXFileSystem
    ) throws(FileSystemFailure) {
        self.directory = directory
        self.privateNamespace = privateNamespace
        folderName = ".recortia-\(UUID().uuidString)"
        guard mkdirat(directory, folderName, 0o700) == 0 else { throw FileSystemFailure(code: errno) }
        let folder = openat(directory, folderName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        // Not opened, or not the folder just made: leave whatever the name leads to.
        guard folder >= 0 else { throw FileSystemFailure(code: errno) }
        var status = stat()
        guard fstat(folder, &status) == 0, status.st_uid == geteuid(),
            POSIXFileSystem.entry(folderName, in: directory, is: FileIdentity(status), type: S_IFDIR)
        else {
            close(folder)
            throw POSIXFileSystem.substitutedFailure
        }
        self.folder = folder
        folderIdentity = FileIdentity(status)
        // Held until the folder is closed, so another save's sweep leaves this folder alone.
        _ = flock(folder, LOCK_EX | LOCK_NB)
        url = destination.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(POSIXFileSystem.stageName, isDirectory: false)
        // From here on `remove()` cleans up. The folder's inherited entries go first, so no entry
        // lets anyone else in; then the file is created inside it, owner-only.
        var failure: Int32?
        do throws(FileSystemFailure) { try POSIXFileSystem.clearACL(folder) } catch { failure = error.code }
        if failure == nil, fchmod(folder, 0o700) != 0 { failure = errno }
        var file: Int32 = -1
        if failure == nil {
            file = openat(
                folder, POSIXFileSystem.stageName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if file < 0 { failure = errno }
        }
        self.file = file
        fileIdentity = FileIdentity(stat())
        if failure == nil {
            do throws(FileSystemFailure) { try POSIXFileSystem.clearACL(file) } catch { failure = error.code }
        }
        var written = 0
        if failure == nil {
            failure = POSIXFileSystem.writeAll(
                data, to: file, written: &written, failAfter: fileSystem.failWrite.map { _ in 3 },
                using: fileSystem.writeBytes)
            if failure == nil, let injected = fileSystem.failWrite { failure = injected }
        }
        if failure == nil, fsync(file) != 0 { failure = errno }
        // Identity once the bytes are on disk: exFAT and FAT number a file by its first cluster.
        if file >= 0, fstat(file, &status) == 0 { fileIdentity = FileIdentity(status) }
        if let failure {
            throw FileSystemFailure(code: failure, leftover: remove())
        }
        fileSystem.afterSync(url)
    }

    /// At most this many leftover folders, and entries in each, are swept per save.
    static let sweepLimit = 32

    /// Removes this user's leftover staging folders in the destination folder, left by a crash or
    /// a failed save: private (owner-only), named `.recortia-<UUID>`, not locked by another save,
    /// each regular file of this user in it removed by the `discard` rule, then the folder if
    /// empty. Only the destination folder itself is searched, and only where owners are enforced.
    func sweepLeftovers() {
        guard privateNamespace else { return }
        for name in Self.entries(of: directory, where: isLeftoverName) { sweep(name) }
    }

    private func isLeftoverName(_ name: String) -> Bool {
        name != folderName && name.hasPrefix(".recortia-") && UUID(uuidString: String(name.dropFirst(10))) != nil
    }

    private func sweep(_ name: String) {
        let leftover = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard leftover >= 0 else { return }
        defer { close(leftover) }
        var status = stat()
        guard fstat(leftover, &status) == 0, status.st_uid == geteuid(), status.st_mode & 0o077 == 0,
            flock(leftover, LOCK_EX | LOCK_NB) == 0
        else { return }
        let user = geteuid()
        for entry in Self.entries(of: leftover, where: { _ in true }) {
            // Something not Recortia's goes back where it was; only a failed move back is reported.
            try? discard(entry, from: leftover) { $0.st_mode & S_IFMT == S_IFREG && $0.st_uid == user }
        }
        if POSIXFileSystem.entry(name, in: directory, is: FileIdentity(status), type: S_IFDIR) {
            unlinkat(directory, name, AT_REMOVEDIR)
        }
    }

    /// Up to `sweepLimit` names of the open folder's entries that match, without "." and "..".
    private static func entries(of folder: Int32, where matches: (String) -> Bool) -> [String] {
        let listing = dup(folder)
        guard listing >= 0 else { return [] }
        guard let stream = fdopendir(listing) else {
            close(listing)
            return []
        }
        defer { closedir(stream) }
        var names: [String] = []
        while names.count < sweepLimit, let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != "..", matches(name) { names.append(name) }
        }
        return names
    }

    /// Fails unless the stage's name still leads to the written file and nothing else does.
    func checkStillStaged() throws(FileSystemFailure) {
        var status = stat()
        guard fstat(file, &status) == 0 else { throw FileSystemFailure(code: errno) }
        fileIdentity = FileIdentity(status)
        guard POSIXFileSystem.entry(POSIXFileSystem.stageName, in: folder, is: fileIdentity, type: S_IFREG) else {
            throw POSIXFileSystem.substitutedFailure
        }
    }

    /// The access a file created in the destination folder gets: the entries the folder gives a
    /// new file, then the mode a file created with 0644 gets under the umask. The entries are read
    /// from an empty probe file created there, then discarded through the private folder.
    func giveNewFileAccess(in directory: Int32, afterProbe: (URL) -> Void) throws(FileSystemFailure) {
        let mode = try POSIXFileSystem.newFileMode()
        if let folderACL = acl_get_fd_np(directory, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(folderACL))
            let name = ".recortia-probe-\(UUID().uuidString)"
            let probe = openat(directory, name, O_RDONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard probe >= 0 else { throw FileSystemFailure(code: errno) }
            defer { close(probe) }
            var status = stat()
            guard fstat(probe, &status) == 0 else { throw FileSystemFailure(code: errno, leftover: name) }
            let identity = FileIdentity(status)
            afterProbe(url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(name))
            try discard(name, from: directory) { $0.st_mode & S_IFMT == S_IFREG && FileIdentity($0) == identity }
            _ = try POSIXFileSystem.copyACL(from: probe, to: file)
        } else if errno != ENOENT, errno != ENOTSUP {
            throw FileSystemFailure(code: errno)
        }
        // Mode last, after any inherited deny entry is in place. Best effort, like an overwrite: a
        // volume that refuses it keeps the file owner-only.
        _ = fchmod(file, mode)
    }

    /// Removes `name` from `source` without ever removing something else that took the name: the
    /// entry is moved into the private folder by exclusive rename, checked there, and removed only
    /// if `isOurs`; otherwise it is moved back by exclusive rename, and the save fails, naming the
    /// entry if it could not be moved back. An entry already gone is not Recortia's to remove.
    func discard(_ name: String, from source: Int32, ifItIs isOurs: (stat) -> Bool) throws(FileSystemFailure) {
        guard privateNamespace else { throw FileSystemFailure(code: EPERM, leftover: name) }
        let holding = "discard-\(UUID().uuidString)"
        guard renameatx_np(source, name, folder, holding, UInt32(RENAME_EXCL)) == 0 else {
            if errno == ENOENT { return }
            throw FileSystemFailure(code: errno, leftover: name)
        }
        var status = stat()
        if fstatat(folder, holding, &status, AT_SYMLINK_NOFOLLOW) == 0, isOurs(status) {
            try removeOwnEntry(holding)
            return
        }
        guard renameatx_np(folder, holding, source, name, UInt32(RENAME_EXCL)) == 0 else { throw hold(holding) }
        throw POSIXFileSystem.substitutedFailure
    }

    /// Removes an entry of the private folder already checked to be Recortia's. Only this user can
    /// change that folder's entries, so the check still holds; elsewhere the entry stays and is named.
    func removeOwnEntry(_ entry: String) throws(FileSystemFailure) {
        guard privateNamespace, unlinkat(folder, entry, 0) == 0 else { throw hold(entry) }
    }

    /// Marks `entry` as something the private folder must keep and returns the failure naming it.
    func hold(_ entry: String) -> FileSystemFailure {
        holdsForeignEntry = true
        return FileSystemFailure(code: EIO, leftover: "\(folderName)/\(entry)")
    }

    /// Removes the unpublished stage and the private folder, and returns what had to stay: an
    /// unpublished stage where the volume does not enforce owners, or the folder when it holds an
    /// entry that is not Recortia's. A published stage is gone from the folder already.
    func remove() -> String? {
        var leftover: String?
        if file >= 0 {
            var status = stat()
            if fstat(file, &status) == 0,
                POSIXFileSystem.entry(POSIXFileSystem.stageName, in: folder, is: FileIdentity(status), type: S_IFREG)
            {
                if !privateNamespace || unlinkat(folder, POSIXFileSystem.stageName, 0) != 0 {
                    leftover = "\(folderName)/\(POSIXFileSystem.stageName)"
                }
            }
            close(file)
        }
        if holdsForeignEntry { leftover = leftover ?? folderName }
        close(folder)
        // Only an empty folder can be removed; one that something else entered stays.
        if leftover == nil, POSIXFileSystem.entry(folderName, in: directory, is: folderIdentity, type: S_IFDIR) {
            unlinkat(directory, folderName, AT_REMOVEDIR)
        }
        return leftover
    }
}

// MARK: - Filenames

enum SafeFilename {
    /// APFS and HFS+ limit a name to 255 UTF-8 bytes.
    static let maxBytes = 255

    /// A single path component that cannot escape its folder, hide itself, or be empty.
    static func sanitize(_ name: String, fallbackExtension: String) -> String {
        let lastComponent = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        var cleaned = String(
            String.UnicodeScalarView(
                lastComponent.unicodeScalars.map { scalar in
                    scalar == ":" || scalar.properties.generalCategory == .control ? "-" : scalar
                }))
        while let first = cleaned.first, first == "." || first.isWhitespace { cleaned.removeFirst() }
        while let last = cleaned.last, last.isWhitespace { cleaned.removeLast() }
        if cleaned.isEmpty { cleaned = "Recortia.\(fallbackExtension)" }
        return truncated(cleaned)
    }

    private static func truncated(_ name: String) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var base = url.deletingPathExtension().lastPathComponent
        while base.utf8.count + suffix.utf8.count > maxBytes, !base.isEmpty { base.removeLast() }
        return base + suffix
    }
}
