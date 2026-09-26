import AppKit
import Domain

/// Publishes a sanitized snapshot to a pasteboard as exactly one stored PNG representation (FR-07,
/// RED-02): no TIFF, file URL, string, or app-private type is written. Readers may still see
/// AppKit's own on-demand translations of that one PNG (a legacy PNG alias and TIFF converted from
/// it), which carry the same sanitized pixels. The app passes `.general`; tests pass a private
/// named pasteboard.
public struct ClipboardSink {
    private let pasteboard: NSPasteboard

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// Replaces the pasteboard contents only after the PNG item is fully prepared. Anything that is
    /// not an encoded PNG snapshot is refused before the pasteboard is touched. Success is reported
    /// only when the pasteboard accepted the write.
    @MainActor
    public func write(_ snapshot: ShareSnapshot) throws(SinkError) {
        guard snapshot.format == .png, !snapshot.pixelSize.isEmpty, snapshot.bytes.starts(with: Self.pngSignature)
        else { throw .clipboardWriteFailed }
        let item = NSPasteboardItem()
        guard item.setData(snapshot.bytes, forType: .png) else { throw .clipboardWriteFailed }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw .clipboardWriteFailed }
    }
}
