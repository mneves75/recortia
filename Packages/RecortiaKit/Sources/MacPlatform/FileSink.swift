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
        let temporary = try writeTemporary(snapshot, in: url.deletingLastPathComponent())
        do {
            if overwrite {
                try fileSystem.replace(from: temporary, to: url)
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
        let temporary = try writeTemporary(snapshot, in: folder)
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

    private func writeTemporary(_ snapshot: ShareSnapshot, in folder: URL) throws(SinkError) -> URL {
        let temporary = folder.appendingPathComponent(".recortia-\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try fileSystem.writeNewFile(snapshot.bytes, at: temporary)
        } catch {
            fileSystem.removeItem(at: temporary)
            throw Self.map(error)
        }
        return temporary
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

/// The few file operations the sink needs, reporting POSIX error codes so failures map precisely.
protocol FileSystemOperations {
    /// Creates `url` exclusively (fails if it exists), writes all bytes, and flushes them to disk.
    func writeNewFile(_ data: Data, at url: URL) throws(FileSystemFailure)
    /// Atomically renames, failing with EEXIST if `destination` exists.
    func moveExclusively(from source: URL, to destination: URL) throws(FileSystemFailure)
    /// Atomically renames, replacing `destination` if it exists.
    func replace(from source: URL, to destination: URL) throws(FileSystemFailure)
    /// Best-effort cleanup of a temporary file.
    func removeItem(at url: URL)
    func itemExists(at url: URL) -> Bool
}

struct POSIXFileSystem: FileSystemOperations {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func writeNewFile(_ data: Data, at url: URL) throws(FileSystemFailure) {
        let descriptor = open(url.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw FileSystemFailure(code: errno) }
        var failure: Int32?
        // Invariant: `buffer` is valid only inside the closure; every access stays within
        // `buffer.count` because `offset` only advances by what write(2) reports it wrote.
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if failure == nil, fsync(descriptor) != 0 { failure = errno }
        if close(descriptor) != 0, failure == nil { failure = errno }
        if let failure { throw FileSystemFailure(code: failure) }
    }

    func moveExclusively(from source: URL, to destination: URL) throws(FileSystemFailure) {
        let result = renamex_np(
            source.path(percentEncoded: false), destination.path(percentEncoded: false), UInt32(RENAME_EXCL))
        if result != 0 { throw FileSystemFailure(code: errno) }
    }

    func replace(from source: URL, to destination: URL) throws(FileSystemFailure) {
        if rename(source.path(percentEncoded: false), destination.path(percentEncoded: false)) != 0 {
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
