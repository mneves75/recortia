import CoreGraphics
import Domain
import Foundation

/// The single approved path from a document to external sinks (FR-07): validate options,
/// render a sanitized flattened raster, encode it fresh with allowlisted metadata, and wrap the
/// bytes with the session's revision and privacy epoch. This file is the only place that
/// constructs a share snapshot (enforced by `ShareSnapshotConstructionTests`).
public struct ExportPipeline: Sendable {
    private let renderer: PrivacyRenderer

    public init(renderer: PrivacyRenderer) {
        self.renderer = renderer
    }

    @concurrent
    public func snapshot(of session: DocumentSession, options: ExportOptions, date: Date) async throws(ExportError)
        -> ShareSnapshot
    {
        do {
            try options.validated()
        } catch {
            // `validated()` only throws ExportOptionsError; the fallback keeps the mapping total.
            throw ExportError.invalidOptions((error as? ExportOptionsError) ?? .invalidScale)
        }
        let document = session.document
        let image: CGImage
        do {
            image = try await renderer.render(document, scale: options.scale)
        } catch {
            throw ExportError.render(error)
        }
        let bytes = try ExportEncoder.encode(image, options: options)
        return ShareSnapshot(
            documentID: document.id, revision: session.revision, privacyEpoch: session.privacyEpoch,
            format: options.format, pixelSize: PixelSize(width: image.width, height: image.height), bytes: bytes,
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
