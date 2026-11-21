import Domain
import Foundation
import MacPlatform
import Testing

// Failure modes (B-10): the file or its folder readable by other users; the file growing without
// bound; Delete leaving the rotated file behind; a write following a link planted at the file's
// name; a write that cannot happen throwing, retrying or blocking instead of dropping the event.
@Suite("Diagnostics log file (B-10)")
struct DiagnosticsLogTests {
    static let date = Date(timeIntervalSince1970: 1_795_000_000)
    static let event = DiagnosticEvent.captureFinished(
        mode: .region, purpose: .edit, duration: .milliseconds(412), width: 1280, height: 800)

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "diagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func size(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    }

    @Test("Writes one typed line per event in an owner-only file and folder")
    func writesTypedLines() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticsLog(directory: root.appending(path: "Logs/Recortia", directoryHint: .isDirectory))
        #expect(await log.existingFiles().isEmpty)
        #expect(await log.append(Self.event, at: Self.date))
        #expect(await log.append(.permissionStatus(permission: .accessibility, granted: true), at: Self.date))

        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(
            text.split(separator: "\n") == [
                Substring(Self.event.line(at: Self.date)),
                Substring(
                    DiagnosticEvent.permissionStatus(permission: .accessibility, granted: true).line(at: Self.date)),
            ])
        #expect(text.hasSuffix("\n"))
        #expect(try permissions(log.fileURL) == 0o600)
        #expect(try permissions(log.directory) == 0o700)
        #expect(log.fileURL.lastPathComponent == "diagnostics.log")
        #expect(await log.existingFiles() == [log.fileURL])
    }

    @Test("A folder or file left with wider permissions is narrowed before the next line")
    func narrowsPermissions() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticsLog(directory: root)
        #expect(await log.append(Self.event, at: Self.date))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.fileURL.path)
        #expect(await log.append(Self.event, at: Self.date))
        #expect(try permissions(log.fileURL) == 0o600)
        #expect(try permissions(root) == 0o700)
    }

    @Test("Past 512 KiB the file becomes diagnostics.1.log, replacing the previous one")
    func rotates() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticsLog(directory: root)
        let lineBytes = Self.event.line(at: Self.date).utf8.count + 1
        let perFile = DiagnosticsLog.rotationBytes / lineBytes
        for _ in 0..<perFile { #expect(await log.append(Self.event, at: Self.date)) }
        #expect(await log.existingFiles() == [log.fileURL], "one file up to the bound")

        #expect(await log.append(Self.event, at: Self.date))
        #expect(await log.existingFiles() == [log.fileURL, log.previousFileURL])
        #expect(try size(log.previousFileURL) == perFile * lineBytes)
        #expect(try size(log.fileURL) == lineBytes)
        #expect(try permissions(log.previousFileURL) == 0o600)

        // A third file's worth replaces the first rotation: never more than two files.
        for _ in 0..<perFile { #expect(await log.append(Self.event, at: Self.date)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(names == ["diagnostics.1.log", "diagnostics.log"])
        let total = try size(log.fileURL) + size(log.previousFileURL)
        #expect(total <= 2 * DiagnosticsLog.rotationBytes)
        #expect(try size(log.fileURL) <= DiagnosticsLog.rotationBytes)
    }

    @Test("Delete removes both files and keeps nothing else")
    func deletesBoth() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticsLog(directory: root)
        #expect(await log.append(Self.event, at: Self.date))
        try Data("old\n".utf8).write(to: log.previousFileURL)
        let unrelated = root.appending(path: "notes.txt")
        try Data("keep".utf8).write(to: unrelated)

        #expect(await log.delete())
        #expect(await log.existingFiles().isEmpty)
        #expect(FileManager.default.fileExists(atPath: unrelated.path), "Delete removes only its own files")
        #expect(await log.delete(), "deleting nothing succeeds")
    }

    @Test("A link at the file's name is never followed; the event is dropped")
    func refusesLinks() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "elsewhere.txt")
        try Data("untouched".utf8).write(to: target)
        let folder = root.appending(path: "Recortia", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = DiagnosticsLog(directory: folder)
        try FileManager.default.createSymbolicLink(at: log.fileURL, withDestinationURL: target)

        #expect(!(await log.append(Self.event, at: Self.date)))
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")

        let linkedFolder = DiagnosticsLog(directory: root.appending(path: "linked", directoryHint: .isDirectory))
        try FileManager.default.createSymbolicLink(at: linkedFolder.directory, withDestinationURL: folder)
        #expect(!(await linkedFolder.append(Self.event, at: Self.date)))
    }

    @Test("An unwritable folder drops the event without throwing")
    func dropsWhenUnwritable() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appending(path: "file-in-the-way")
        try Data().write(to: blocked)
        let log = DiagnosticsLog(directory: blocked)
        #expect(!(await log.append(Self.event, at: Self.date)))
        #expect(await log.existingFiles().isEmpty)
    }

    @Test("The standard folder is ~/Library/Logs/Recortia")
    func standardFolder() throws {
        let folder = try #require(DiagnosticsLog.standardDirectory())
        #expect(folder.path.hasSuffix("/Library/Logs/Recortia"))
    }
}
