import AppKit
import Domain
import Foundation
import Imaging
import Synchronization
import Testing

@testable import MacPlatform

@Suite("Image input: bounded file reads (FR-03, IO-01)")
struct ImageInputFileTests {
    /// A sparse file of exactly `size` bytes: fast to create, no real disk usage.
    private func sparseFile(size: UInt64, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("input-\(size).png")
        #expect(FileManager.default.createFile(atPath: url.path, contents: TestSupport.pngSignature))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
        return url
    }

    @Test("A file of exactly 64 MiB is read in full")
    func exactlyAtLimit() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = try sparseFile(size: UInt64(ImportLimits.maxCompressedBytes), in: folder)
        let data = try ImageInput.readFile(at: url)
        #expect(data.count == ImportLimits.maxCompressedBytes)
        #expect(data.prefix(8) == TestSupport.pngSignature)
    }

    @Test("A file one byte over 64 MiB is rejected")
    func oneByteOver() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = try sparseFile(size: UInt64(ImportLimits.maxCompressedBytes) + 1, in: folder)
        #expect(throws: ImportError.tooManyBytes) { try ImageInput.readFile(at: url) }
    }

    @Test("A huge declared size is rejected before any read")
    func hugeFile() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = try sparseFile(size: 1 << 40, in: folder)
        #expect(throws: ImportError.tooManyBytes) { try ImageInput.readFile(at: url) }
    }

    @Test("A small file is returned byte for byte and is not modified")
    func smallFile() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("small.png")
        let bytes = TestSupport.pngSignature + Data([1, 2, 3])
        try bytes.write(to: url)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(try ImageInput.readFile(at: url) == bytes)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test("Missing files and directories are unreadable")
    func unreadable() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        #expect(throws: ImportError.unreadable) {
            try ImageInput.readFile(at: folder.appendingPathComponent("none.png"))
        }
        #expect(throws: ImportError.unreadable) { try ImageInput.readFile(at: folder) }
    }

    /// Resumes a continuation at most once; the read and the deadline race for it.
    private final class Once: Sendable {
        private let claimed = Mutex(false)
        func claim() -> Bool {
            claimed.withLock { taken in
                defer { taken = true }
                return !taken
            }
        }
    }

    /// `readFile` on a GCD thread, or nil when it has not returned within `seconds`.
    private func readFile(at url: URL, deadline seconds: Double) async -> Result<Data, ImportError>? {
        await withCheckedContinuation { continuation in
            let once = Once()
            DispatchQueue.global().async {
                let result = Result<Data, ImportError> { () throws(ImportError) in try ImageInput.readFile(at: url) }
                if once.claim() { continuation.resume(returning: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    @Test("A FIFO is refused at once instead of blocking the open until a writer appears")
    func fifoIsRefusedWithoutBlocking() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let fifo = folder.appendingPathComponent("pipe.png")
        try #require(Darwin.mkfifo(fifo.path, 0o600) == 0)
        let outcome = await readFile(at: fifo, deadline: 2)
        if outcome == nil {
            // Regression: the reader is stuck in open(2). Open the write end so it returns.
            let writer = Darwin.open(fifo.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { Darwin.close(writer) }
        }
        #expect(outcome != nil, "readFile blocked on a FIFO")
        #expect(outcome.map { if case .failure(.unreadable) = $0 { true } else { false } } == true)
    }

    @Test("A symbolic link, even to a regular file, is not followed")
    func symlinkIsRefused() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let target = folder.appendingPathComponent("real.png")
        try (TestSupport.pngSignature + Data([1, 2, 3])).write(to: target)
        #expect(try ImageInput.readFile(at: target).count == 11)  // control: the target itself reads
        let link = folder.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: ImportError.unreadable) { try ImageInput.readFile(at: link) }
    }
}

@MainActor
@Suite("Image input: explicit pasteboard reads (FR-03, IO-01)")
struct ImageInputPasteboardTests {
    private let jpeg = NSPasteboard.PasteboardType("public.jpeg")

    @Test("PNG is preferred over TIFF when both are present")
    func prefersPNG() {
        let pasteboard = TestSupport.privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data([1]), forType: .tiff)
        item.setData(Data([2]), forType: .png)
        pasteboard.writeObjects([item])
        #expect(ImageInput.readPasteboard(pasteboard) == Data([2]))
    }

    @Test("JPEG is read, then TIFF as the last accepted type")
    func jpegThenTIFF() {
        let pasteboard = TestSupport.privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data([3]), forType: jpeg)
        #expect(ImageInput.readPasteboard(pasteboard) == Data([3]))
        pasteboard.clearContents()
        pasteboard.setData(Data([4]), forType: .tiff)
        #expect(ImageInput.readPasteboard(pasteboard) == Data([4]))
    }

    @Test("Text, file URLs, and empty pasteboards yield nothing")
    func nonImageContent() throws {
        let pasteboard = TestSupport.privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(ImageInput.readPasteboard(pasteboard) == nil)
        pasteboard.setString("https://example.com/image.png", forType: .string)
        #expect(ImageInput.readPasteboard(pasteboard) == nil)
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/image.png") as NSURL])
        #expect(ImageInput.readPasteboard(pasteboard) == nil)
    }
}

@Suite("External links open only for http and https (FR-08, THREAT_MODEL)")
struct ExternalLinkPolicyTests {
    @Test(
        "Web URLs with a host are allowed",
        arguments: ["https://example.com", "http://example.com/a?b=c", "HTTPS://EXAMPLE.COM/path"])
    func allowsWeb(string: String) throws {
        #expect(ExternalLinkPolicy.canOpen(try #require(URL(string: string))))
    }

    @Test(
        "Every other scheme, and web URLs without a host, are refused",
        arguments: [
            "file:///etc/passwd", "javascript:alert(1)", "mailto:a@example.com", "ftp://example.com",
            "x-apple.systempreferences:com.apple.preference.security", "sms:123", "data:text/plain,hi",
            "https:", "http:///path", "recortia://open", "ssh://host",
        ])
    func refusesOthers(string: String) throws {
        #expect(!ExternalLinkPolicy.canOpen(try #require(URL(string: string))))
    }

    @Test(
        "Web URLs with a user or password component are refused (the host is not what it looks like)",
        arguments: [
            "https://trusted@evil.example", "https://trusted.example@evil.example/login",
            "http://user:pass@example.com/", "https://:pw@example.com", "https://@example.com",
        ])
    func refusesUserInfo(string: String) throws {
        #expect(!ExternalLinkPolicy.canOpen(try #require(URL(string: string))))
    }
}
