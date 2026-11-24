import Domain
import Foundation

/// The optional local diagnostics file (B-10): typed event lines only, in an owner-only file
/// (0600) inside an owner-only folder (0700), `~/Library/Logs/Recortia/diagnostics.log` in the
/// app. Past `rotationBytes` the file becomes `diagnostics.1.log`, replacing the previous one, so
/// at most two bounded files exist. Recortia never sends it anywhere; the person attaches it to a
/// report themselves.
///
/// One serial writer off the main actor, using FileManager and FileHandle only. A line that cannot
/// be written is dropped: no retry and no message, so a full disk cannot start an alert loop.
public actor DiagnosticsLog {
    public static let fileName = "diagnostics.log"
    public static let previousFileName = "diagnostics.1.log"
    public static let rotationBytes = 512 * 1024

    public nonisolated let directory: URL
    public nonisolated var fileURL: URL { directory.appending(path: Self.fileName, directoryHint: .notDirectory) }
    public nonisolated var previousFileURL: URL {
        directory.appending(path: Self.previousFileName, directoryHint: .notDirectory)
    }

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Logs/Recortia`; nil only when the system reports no Library folder.
    public static func standardDirectory() -> URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appending(path: "Logs/Recortia", directoryHint: .isDirectory)
    }

    /// Appends the event's line; false when it was dropped.
    @discardableResult
    public func append(_ event: DiagnosticEvent, at date: Date) -> Bool {
        let line = Data((event.line(at: date) + "\n").utf8)
        do {
            try prepareDirectory()
            if let size = try regularFileSize(fileURL), size + line.count > Self.rotationBytes { try rotate() }
            try prepareFile()
            let handle = try FileHandle(forWritingTo: fileURL)
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                try? handle.close()
                throw error
            }
            try handle.close()
            return true
        } catch {
            return false  // dropped by design (see the type's documentation)
        }
    }

    /// Removes both files; true when neither exists afterwards. Touches nothing else in the folder.
    @discardableResult
    public func delete() -> Bool {
        let fileManager = FileManager.default
        var allSucceeded = true
        for url in [fileURL, previousFileURL] where itemType(url) != nil {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                allSucceeded = false
            }
        }
        return allSucceeded && existingFiles().isEmpty
    }

    /// The diagnostics files that exist now, current first.
    public func existingFiles() -> [URL] {
        [fileURL, previousFileURL].filter { itemType($0) != nil }
    }

    // MARK: Private

    private enum Refusal: Error {
        case notADirectory, notARegularFile, notCreated
    }

    /// The type of the item itself, never of what a link points to; nil when nothing is there.
    private func itemType(_ url: URL) -> FileAttributeType? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.type] as? FileAttributeType
    }

    private func prepareDirectory() throws {
        let fileManager = FileManager.default
        switch itemType(directory) {
        case nil:
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        case .typeDirectory?:
            break
        default:
            throw Refusal.notADirectory  // a link or a file where the folder belongs
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func regularFileSize(_ url: URL) throws -> Int? {
        guard let type = itemType(url) else { return nil }
        guard type == .typeRegular else { throw Refusal.notARegularFile }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private func prepareFile() throws {
        let fileManager = FileManager.default
        switch itemType(fileURL) {
        case nil:
            guard fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw Refusal.notCreated }
        case .typeRegular?:
            break
        default:
            throw Refusal.notARegularFile
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func rotate() throws {
        let fileManager = FileManager.default
        switch itemType(previousFileURL) {
        case nil: break
        case .typeRegular?: try fileManager.removeItem(at: previousFileURL)
        default: throw Refusal.notARegularFile
        }
        try fileManager.moveItem(at: fileURL, to: previousFileURL)
    }
}
