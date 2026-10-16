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
    /// opened read-only and never modified. The open is non-blocking and does not follow a final
    /// symbolic link, so a FIFO or device is refused at once instead of blocking the caller.
    public static func readFile(at url: URL) throws(ImportError) -> Data {
        guard url.isFileURL else { throw .unreadable }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw .unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            // Closing a read-only descriptor has no data to lose; a close error cannot change the result.
            try? handle.close()
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw .unreadable }
        // A regular file never blocks; clear O_NONBLOCK so reads behave normally.
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw .unreadable }
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
    ///
    /// TIFF is read on purpose but never decoded: the bounded importer accepts only PNG and JPEG
    /// (FR-03), so a TIFF-only clipboard reaches the decoder and is refused as an unsupported
    /// format, which tells the user why, instead of "no image on the clipboard".
    @MainActor
    public static func readPasteboard(_ pasteboard: NSPasteboard) -> Data? {
        let accepted: [NSPasteboard.PasteboardType] = [.png, NSPasteboard.PasteboardType("public.jpeg"), .tiff]
        for type in accepted {
            if let data = pasteboard.data(forType: type) { return data }
        }
        return nil
    }
}
