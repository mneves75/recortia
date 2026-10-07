import CoreGraphics
import Domain
import Foundation

/// The single approved path from a document, or a pin's sanitized raster, to external sinks
/// (FR-07, PIN-02): validate options, render a sanitized flattened raster, encode it fresh with
/// allowlisted metadata, and wrap the bytes with the source's revision and privacy epoch. This
/// file is the only place that constructs a share snapshot (`ShareSnapshotConstructionTests`).
public struct ExportPipeline: Sendable {
    private let renderer: PrivacyRenderer

    public init(renderer: PrivacyRenderer) {
        self.renderer = renderer
    }

    @concurrent
    public func snapshot(of session: DocumentSession, options: ExportOptions, date: Date) async throws(ExportError)
        -> ShareSnapshot
    {
        try Self.validate(options)
        let document = session.document
        let image: CGImage
        do {
            image = try await renderer.render(document, scale: options.scale)
        } catch {
            throw ExportError.render(error)
        }
        return try Self.encode(
            image, documentID: document.id, revision: session.revision, privacyEpoch: session.privacyEpoch,
            options: options, date: date)
    }

    /// A pin's raster: what `PrivacyRenderer` produced for the pinned document at 1x (FR-09,
    /// PIN-02). It is encoded fresh, never resampled, under the pin's own export identity.
    @concurrent
    public func snapshot(
        ofPinned image: CGImage, exportID: DocumentID, privacyEpoch: UInt64, options: ExportOptions, date: Date
    ) async throws(ExportError) -> ShareSnapshot {
        try Self.validate(options)
        guard options.scale == 1 else { throw ExportError.invalidOptions(.invalidScale) }
        return try Self.encode(
            image, documentID: exportID, revision: 0, privacyEpoch: privacyEpoch, options: options, date: date)
    }

    private static func validate(_ options: ExportOptions) throws(ExportError) {
        do {
            try options.validated()
        } catch {
            // `validated()` only throws ExportOptionsError; the fallback keeps the mapping total.
            throw ExportError.invalidOptions((error as? ExportOptionsError) ?? .invalidScale)
        }
    }

    private static func encode(
        _ image: CGImage, documentID: DocumentID, revision: UInt64, privacyEpoch: UInt64, options: ExportOptions,
        date: Date
    ) throws(ExportError) -> ShareSnapshot {
        let bytes = try ExportEncoder.encode(image, options: options)
        return ShareSnapshot(
            documentID: documentID, revision: revision, privacyEpoch: privacyEpoch, format: options.format,
            pixelSize: PixelSize(width: image.width, height: image.height), bytes: bytes,
            suggestedFilename: ExportFilename.make(for: date, format: options.format))
    }
}

extension DocumentSession {
    /// Whether a snapshot still matches this session's document, revision, and privacy epoch.
    /// Anything produced before a later edit, mask change, undo, or redo is stale.
    public func accepts(_ snapshot: ShareSnapshot) -> Bool {
        snapshot.documentID == document.id && snapshot.revision == revision && snapshot.privacyEpoch == privacyEpoch
    }
}
