import CoreGraphics
import Domain
import Foundation

public enum RenderError: Error, Equatable, Sendable {
    case invalidScale
    case invalidGeometry
    case unknownAsset
    /// A layer references an asset whose pixels are not in the store.
    case missingPixels
    case translucentSecureMask
    /// The estimated working memory exceeds `RenderLimits.maxWorkingBytes`; nothing was allocated.
    case budgetExceeded(estimatedBytes: Int, limit: Int)
    case allocationFailed
    case canceled
}

/// Render budgets, checked before any buffer is allocated.
///
/// SPEC §10 targets ≤ 512 MiB for the whole heavy 40 MP workflow. The renderer's own buffers are
/// budgeted at 384 MiB (a sanitized copy of each distinct source, cropped copies, one output
/// raster, a second one for presentation, and the largest effect/magnifier scratch buffer), which
/// admits a plain 40 MP export (≈ 320 MiB) but refuses, for example, three 40 MP sources composed
/// into one 40 MP output. Raw pixels already in `ImageStore`, ImageIO's encoder buffers, and
/// framework allocations are outside this estimate; the process-wide 512 MiB target still needs
/// measurement on hardware (SPEC §10) and is not claimed here.
public enum RenderLimits {
    public static let maxOutputPixels = ImportLimits.maxPixelArea
    public static let maxOutputSide = 32_768
    public static let maxWorkingBytes = 384 * 1024 * 1024
}

/// Result of a render plus the thread evidence used to prove rendering stays off the main thread.
package struct RenderOutcome: Sendable {
    package let image: CGImage
    package let renderedOnMainThread: Bool
}

/// Produces sanitized, flattened rasters from a document (SPEC §8). Rendering is `@concurrent`:
/// it runs on the global concurrent executor even when awaited from the main actor.
public struct PrivacyRenderer: Sendable {
    private let store: ImageStore

    public init(store: ImageStore) {
        self.store = store
    }

    /// Full sanitized, flattened output (SPEC §8 order), at `scale` × `document.resizeScale`.
    @concurrent
    public func render(_ document: Document, scale: Double) async throws(RenderError) -> CGImage {
        try await renderOutcome(document, scale: scale).image
    }

    /// Sanitized raster layers, cosmetic effects, and secure masks only (no annotations,
    /// callouts, crop, resize, or presentation), covering the whole canvas at `scale` — the
    /// editor's zoom-independent backing store, drawn under its live annotation layer.
    @concurrent
    public func renderBase(_ document: Document, scale: Double) async throws(RenderError) -> CGImage {
        let sources = await store.images(for: Set(document.layers.map(\.assetID)))
        if Task.isCancelled { throw RenderError.canceled }
        return try RenderEngine.renderBase(document, sources: sources, scale: scale)
    }

    @concurrent
    package func renderOutcome(_ document: Document, scale: Double) async throws(RenderError) -> RenderOutcome {
        let sources = await store.images(for: Set(document.layers.map(\.assetID)))
        if Task.isCancelled { throw RenderError.canceled }
        let onMain = RenderEngine.isMainThread()
        let image = try RenderEngine.render(document, sources: sources, scale: scale)
        return RenderOutcome(image: image, renderedOnMainThread: onMain)
    }
}
