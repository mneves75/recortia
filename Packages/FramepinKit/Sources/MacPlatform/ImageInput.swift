import AppKit
import Darwin
import Domain
import Imaging

/// Bounded image input for Open and Paste (FR-03, IO-01). Returns raw bytes for the Imaging
/// decoder, which validates format, dimensions, and pixel budget.
public enum ImageInput {
    /// Reads a regular file of at most `ImportLimits.maxCompressedBytes`. The size is checked on
    /// the open descriptor before reading, and the read itself stops one byte past the limit, so a
    /// file that grows in between is still rejected without an unbounded allocation. The source is
    /// opened read-only and never modified.
    public static func readFile(at url: URL) throws(ImportError) -> Data {
        guard url.isFileURL else { throw .unreadable }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw .unreadable
        }
        defer {
            // Closing a read-only descriptor has no data to lose; a close error cannot change the result.
            try? handle.close()
        }

        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw .unreadable }
        let limit = ImportLimits.maxCompressedBytes
        guard info.st_size >= 0, info.st_size <= off_t(limit) else { throw .tooManyBytes }

        let data: Data
        do {
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            throw .unreadable
        }
        if ImportLimits.check(byteCount: data.count) != nil { throw .tooManyBytes }
        return data
    }

    /// Image data from `pasteboard`, preferring PNG, then JPEG, then TIFF. Called only for an
    /// explicit Paste or Open from Clipboard; nothing polls the pasteboard. Text, URLs, and file
    /// references are ignored: no file or network content is fetched.
    @MainActor
    public static func readPasteboard(_ pasteboard: NSPasteboard) -> Data? {
        let accepted: [NSPasteboard.PasteboardType] = [.png, NSPasteboard.PasteboardType("public.jpeg"), .tiff]
        for type in accepted {
            if let data = pasteboard.data(forType: type) { return data }
        }
        return nil
    }
}
