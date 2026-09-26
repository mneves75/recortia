import Foundation

/// The only value any external sink (clipboard, file, drag-out, future upload) may accept
/// (FR-07). It holds freshly encoded, sanitized bytes and no reference to source assets.
///
/// The initializer is `package`-scoped so code outside FramepinKit cannot fabricate one;
/// `ShareSnapshotConstructionTests` fails if anything other than the export pipeline calls it.
public struct ShareSnapshot: Hashable, Sendable {
    public let documentID: DocumentID
    public let revision: UInt64
    public let privacyEpoch: UInt64
    public let format: ExportFormat
    public let pixelSize: PixelSize
    public let bytes: Data
    public let suggestedFilename: String

    package init(
        documentID: DocumentID, revision: UInt64, privacyEpoch: UInt64, format: ExportFormat, pixelSize: PixelSize,
        bytes: Data, suggestedFilename: String
    ) {
        self.documentID = documentID
        self.revision = revision
        self.privacyEpoch = privacyEpoch
        self.format = format
        self.pixelSize = pixelSize
        self.bytes = bytes
        self.suggestedFilename = suggestedFilename
    }
}
