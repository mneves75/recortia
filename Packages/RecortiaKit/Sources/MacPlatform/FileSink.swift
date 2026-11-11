import Darwin
import Domain
import Foundation

public struct FileSink {
    private let fileSystem: any FileSystemOperations

    /// Upper bound on collision attempts in `saveUnique`, so a hostile folder cannot spin forever.
    static let maxUniqueAttempts = 1_000

    public init(fileManager: FileManager = .default) {
        self.init(fileSystem: POSIXFileSystem(fileManager: fileManager))
    }

    init(fileSystem: any FileSystemOperations) {
        self.fileSystem = fileSystem
    }

    /// Writes the snapshot to a user-selected `url` (FR-07, EXP-02). The bytes go to a temporary
    /// file in the same directory, then an atomic rename commits them. Without `overwrite`, an
    /// existing destination is refused, including one created concurrently. On any failure the
    /// previous destination is untouched and the temporary file is removed.
    public func save(_ snapshot: ShareSnapshot, to url: URL, overwrite: Bool) throws(SinkError) -> URL {
        guard url.isFileURL else { throw .writeFailed(code: Int(EINVAL)) }
        if !overwrite, fileSystem.itemExists(at: url) { throw .destinationExists }
        // A replaced file may be private: write it owner-only and let `replace` copy its access.
        let replacing = overwrite && fileSystem.itemExists(at: url)
        let (temporary, identity) = try writeTemporary(
            snapshot, in: url.deletingLastPathComponent(), access: replacing ? .replacement : .newFile)
        do {
            if overwrite {
                try fileSystem.replace(from: temporary, to: url, expecting: identity)
            } else {
                try fileSystem.moveExclusively(from: temporary, to: url)
            }
        } catch {
            fileSystem.removeItem(at: temporary)
            throw Self.map(error)
        }
        return url
    }

    /// Saves under the snapshot's sanitized suggested name in an authorized `folder`, adding
    /// " (n)" before the extension until the name is free. Never overwrites.
    public func saveUnique(_ snapshot: ShareSnapshot, in folder: URL) throws(SinkError) -> URL {
        guard folder.isFileURL else { throw .writeFailed(code: Int(EINVAL)) }
        let name = SafeFilename.sanitize(snapshot.suggestedFilename, fallbackExtension: snapshot.format.fileExtension)
        let (temporary, _) = try writeTemporary(snapshot, in: folder, access: .newFile)
        for attempt in 1...Self.maxUniqueAttempts {
            let candidate = folder.appendingPathComponent(
                ExportFilename.deduplicated(name, attempt: attempt), isDirectory: false)
            do {
                try fileSystem.moveExclusively(from: temporary, to: candidate)
                return candidate
            } catch  where error.code == EEXIST {
                continue
            } catch {
                fileSystem.removeItem(at: temporary)
                throw Self.map(error)
            }
        }
        fileSystem.removeItem(at: temporary)
        throw .destinationExists
    }

    private func writeTemporary(_ snapshot: ShareSnapshot, in folder: URL, access: TemporaryFileAccess)
        throws(SinkError) -> (URL, FileIdentity)
    {
        let temporary = folder.appendingPathComponent(".recortia-\(UUID().uuidString).tmp", isDirectory: false)
        do {
            let identity = try fileSystem.writeNewFile(snapshot.bytes, at: temporary, access: access)
            return (temporary, identity)
        } catch {
            fileSystem.removeItem(at: temporary)
            throw Self.map(error)
        }
    }

    static func map(_ failure: FileSystemFailure) -> SinkError {
        switch failure.code {
        case ENOSPC, EDQUOT: .diskFull
        case EACCES, EPERM, EROFS: .accessDenied
        case ENOENT, ENXIO, ENODEV: .volumeUnavailable
        case EEXIST: .destinationExists
        default: .writeFailed(code: Int(failure.code))
        }
    }
}

// MARK: - File-system seam

struct FileSystemFailure: Error, Equatable, Sendable {
    let code: Int32
}

/// What the temporary file becomes. Either way its bytes are written while it is owner-only and
/// without the ACL entries it inherited from its folder; those entries are removed right after
/// creation, before the first byte.
enum TemporaryFileAccess: Equatable, Sendable {
    /// It will replace an existing file: it stays so until `replace` gives it the replaced file's
    /// access.
    case replacement
    /// It will become a new file: once written, it gets back the entries the folder gives any file
    /// created in it, then the mode a file created with 0644 gets under the umask.
    case newFile
}

/// The written file itself, so later metadata changes reach it and not whatever its name points to.
struct FileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
}

/// The few file operations the sink needs, reporting POSIX error codes so failures map precisely.
protocol FileSystemOperations {
    /// Creates `url` exclusively (fails if it exists), writes all bytes, flushes them to disk,
    /// gives the file the access `access` describes, and returns the created file's identity.
    func writeNewFile(_ data: Data, at url: URL, access: TemporaryFileAccess) throws(FileSystemFailure) -> FileIdentity
    /// Atomically renames, failing with EEXIST if `destination` exists.
    func moveExclusively(from source: URL, to destination: URL) throws(FileSystemFailure)
    /// Atomically renames, replacing `destination` if it exists and keeping its permission bits and
    /// ACL. Fails with EPERM, leaving `destination` untouched, unless `source` still names the
    /// file `identity` describes and nothing else does.
    func replace(from source: URL, to destination: URL, expecting identity: FileIdentity) throws(FileSystemFailure)
    /// Best-effort cleanup of a temporary file.
    func removeItem(at url: URL)
    func itemExists(at url: URL) -> Bool
}

struct POSIXFileSystem: FileSystemOperations {
    /// Reported when the temporary file's name no longer leads to the written file alone.
    static let substitutedFailure = FileSystemFailure(code: EPERM)

    private let fileManager: FileManager
    /// Test seam: runs once the bytes are on disk, before a new file gets its final access.
    private let afterSync: (URL) -> Void

    init(fileManager: FileManager = .default, afterSync: @escaping (URL) -> Void = { _ in }) {
        self.fileManager = fileManager
        self.afterSync = afterSync
    }

    func writeNewFile(_ data: Data, at url: URL, access: TemporaryFileAccess) throws(FileSystemFailure)
        -> FileIdentity
    {
        let newFileMode = access == .newFile ? try newFileMode() : nil
        let descriptor = open(url.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw FileSystemFailure(code: errno) }
        var failure: Int32?
        var status = stat()
        if fstat(descriptor, &status) != 0 { failure = errno }
        var inherited: acl_t?
        if failure == nil {
            do throws(FileSystemFailure) {
                inherited = try Self.takeInheritedACL(descriptor)
            } catch {
                failure = error.code
            }
        }
        defer { if let inherited { acl_free(UnsafeMutableRawPointer(inherited)) } }
        if failure == nil { failure = Self.writeAll(data, to: descriptor) }
        if failure == nil, fsync(descriptor) != 0 { failure = errno }
        if failure == nil { afterSync(url) }
        if failure == nil, access == .newFile, let inherited,
            acl_set_fd_np(descriptor, inherited, ACL_TYPE_EXTENDED) != 0
        {
            failure = errno
        }
        // Mode last, after any inherited deny entry is back. Best effort, like `replace`: a volume
        // that refuses it keeps the file owner-only.
        if failure == nil, let newFileMode { _ = fchmod(descriptor, newFileMode) }
        if close(descriptor) != 0, failure == nil { failure = errno }
        if let failure { throw FileSystemFailure(code: failure) }
        return FileIdentity(device: status.st_dev, inode: status.st_ino)
    }

    /// The mode open(2) gives a file requested as 0644 under the current umask, which is what a new
    /// save always ended with. Reading the umask needs macOS 27 or a process-wide change that other
    /// threads would see, so an empty probe file is created and removed in this user's temporary
    /// folder instead.
    private func newFileMode() throws(FileSystemFailure) -> mode_t {
        let probe = fileManager.temporaryDirectory.appendingPathComponent(
            ".recortia-mode-\(UUID().uuidString)", isDirectory: false
        ).path(percentEncoded: false)
        let descriptor = open(probe, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw FileSystemFailure(code: errno) }
        unlink(probe)
        var status = stat()
        let result = fstat(descriptor, &status)
        let failure = errno
        close(descriptor)
        guard result == 0 else { throw FileSystemFailure(code: failure) }
        return status.st_mode & 0o777
    }

    /// Returns the error code of the first failed write(2), or nil once every byte is written.
    private static func writeAll(_ data: Data, to descriptor: Int32) -> Int32? {
        // Invariant: `buffer` is valid only inside the closure; every access stays within
        // `buffer.count` because `offset` only advances by what write(2) reports it wrote.
        data.withUnsafeBytes { buffer -> Int32? in
            guard let base = buffer.baseAddress else { return nil }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += written
            }
            return nil
        }
    }

    /// Removes, through the descriptor, the ACL a new file inherited from its folder and returns it
    /// for the caller to free; nil when there was none or the volume has no ACLs.
    private static func takeInheritedACL(_ descriptor: Int32) throws(FileSystemFailure) -> acl_t? {
        guard let inherited = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == ENOTSUP { return nil }
            throw FileSystemFailure(code: errno)
        }
        do throws(FileSystemFailure) {
            try clearACL(descriptor)
        } catch {
            acl_free(UnsafeMutableRawPointer(inherited))
            throw error
        }
        return inherited
    }

    func moveExclusively(from source: URL, to destination: URL) throws(FileSystemFailure) {
        let result = renamex_np(
            source.path(percentEncoded: false), destination.path(percentEncoded: false), UInt32(RENAME_EXCL))
        if result != 0 { throw FileSystemFailure(code: errno) }
    }

    func replace(from source: URL, to destination: URL, expecting identity: FileIdentity) throws(FileSystemFailure) {
        let descriptor = try Self.openWritten(source, expecting: identity)
        // Read-only and used for metadata only: closing it cannot lose data.
        defer { close(descriptor) }
        var existing = stat()
        var copiedACL = false
        if stat(destination.path(percentEncoded: false), &existing) == 0 {
            // Best effort: a volume that refuses chmod keeps the owner-only temporary mode.
            _ = fchmod(descriptor, existing.st_mode & 0o777)
            copiedACL = try copyACL(from: destination, to: descriptor)
        } else if errno != ENOENT {
            throw FileSystemFailure(code: errno)
        }
        if rename(source.path(percentEncoded: false), destination.path(percentEncoded: false)) != 0 {
            let failure = errno
            // The copied ACL can deny this user deleting the temporary file as well (an entry that
            // denies delete is also why the rename failed); drop it so the caller's cleanup works.
            // Best effort, before cleanup of a failure that is already being reported.
            if copiedACL { try? Self.clearACL(descriptor) }
            throw FileSystemFailure(code: failure)
        }
    }

    /// Opens `url` for metadata changes only while it names the written file and nothing else: not
    /// a link (O_NOFOLLOW) or a FIFO (O_NONBLOCK, then the regular-file check), the same device and
    /// inode, and a single name, so a link planted by another account cannot redirect them.
    private static func openWritten(_ url: URL, expecting identity: FileIdentity) throws(FileSystemFailure) -> Int32 {
        let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw errno == ELOOP ? substitutedFailure : FileSystemFailure(code: errno)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let failure = errno
            close(descriptor)
            throw FileSystemFailure(code: failure)
        }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_dev == identity.device,
            status.st_ino == identity.inode, status.st_nlink == 1
        else {
            close(descriptor)
            throw substitutedFailure
        }
        return descriptor
    }

    /// A replaced file in a shared folder may carry its own ACL entries; the new file must keep
    /// them. If they cannot be copied, the replace fails and the destination stays as it was.
    /// Returns whether an ACL was applied to the temporary file.
    private func copyACL(from destination: URL, to descriptor: Int32) throws(FileSystemFailure) -> Bool {
        guard let acl = acl_get_file(destination.path(percentEncoded: false), ACL_TYPE_EXTENDED) else {
            // ENOENT: the file has no ACL; ENOTSUP: the volume has no ACLs at all.
            if errno == ENOENT || errno == ENOTSUP { return false }
            throw FileSystemFailure(code: errno)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        if acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) != 0 {
            throw FileSystemFailure(code: errno)
        }
        return true
    }

    /// Removes every ACL entry of the open file; a volume without ACLs has none to remove.
    private static func clearACL(_ descriptor: Int32) throws(FileSystemFailure) {
        guard let empty = acl_init(0) else { throw FileSystemFailure(code: errno) }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        if acl_set_fd_np(descriptor, empty, ACL_TYPE_EXTENDED) != 0, errno != ENOTSUP {
            throw FileSystemFailure(code: errno)
        }
    }

    func removeItem(at url: URL) {
        // Cleanup after a failure that is already being reported; a leftover hidden temporary
        // file is harmless and a second error would only mask the first.
        _ = unlink(url.path(percentEncoded: false))
    }

    func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path(percentEncoded: false))
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
