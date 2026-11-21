import Domain
import Foundation
import Imaging

/// Automatic masking's detector (FR-06 amendment): the pattern sweep over a stored capture, and the
/// same sweep's text lines for text-only redaction (A-6). The pixels are read inside Imaging; this
/// adapter sees only the rectangles it returns.
@MainActor
public final class LiveSensitiveText: SensitiveTextService {
    private let store: ImageStore
    private let scanner = SensitiveTextScanner()
    private static let languages = [Locale.Language(identifier: "en-US"), Locale.Language(identifier: "pt-BR")]

    public init(store: ImageStore) {
        self.store = store
    }

    public func sensitiveRegions(in asset: ImageAssetInfo) async throws -> [PixelRect] {
        let regions = try await scanner.sensitiveRegions(
            of: asset.id, in: store, pixelsPerPoint: Self.pixelsPerPoint(of: asset.origin), languages: Self.languages)
        // The scanner returns whole-pixel rectangles; rounding only drops floating-point noise.
        return regions.map {
            PixelRect(
                x: Int($0.rect.minX.rounded()), y: Int($0.rect.minY.rounded()), width: Int($0.rect.width.rounded()),
                height: Int($0.rect.height.rounded()))
        }
    }

    public func textLineRegions(in asset: ImageAssetInfo, within area: PixelRect) async throws -> [PixelRect] {
        try await scanner.textLineRegions(
            of: asset.id, in: store, within: area, pixelsPerPoint: Self.pixelsPerPoint(of: asset.origin),
            languages: Self.languages)
    }

    /// The density the sweep is laid out for: a capture's and a scrolling capture's own, both measured
    /// from Recortia's capture geometry. An opened or pasted image is always 1, the slower sweep that
    /// scales up more: a density its file declares is untrusted and must never lower it (decisions.md).
    static func pixelsPerPoint(of origin: AssetOrigin) -> Double {
        switch origin {
        case .captured(let geometry): geometry.pointPixelScale
        case .scrollCapture(_, let scale): scale
        case .imported, .pasted: 1
        }
    }
}
