import Foundation

/// The only value any external sink (clipboard, file, drag-out, GitHub upload) may accept
/// (FR-07, NET-01). It holds freshly encoded, sanitized bytes and no reference to source assets.
///
/// The initializer is `package`-scoped so code outside RecortiaKit cannot fabricate one;
/// `ShareSnapshotConstructionTests` fails if anything other than the export pipeline calls it.
public struct ShareSnapshot: Hashable, Sendable {
    public let documentID: DocumentID
    public let revision: UInt64
    public let privacyEpoch: UInt64
    public let format: ExportFormat
    public let pixelSize: PixelSize
    public let bytes: Data
    /// The template-rendered name, with how to number it while taken (FR-07, A-9).
    public let filename: ExportName

    /// The first name to try: what a drag or a save panel offers.
    public var suggestedFilename: String { filename.name(attempt: 1) }

    package init(
        documentID: DocumentID, revision: UInt64, privacyEpoch: UInt64, format: ExportFormat, pixelSize: PixelSize,
        bytes: Data, filename: ExportName
    ) {
        self.documentID = documentID
        self.revision = revision
        self.privacyEpoch = privacyEpoch
        self.format = format
        self.pixelSize = pixelSize
        self.bytes = bytes
        self.filename = filename
    }
}
