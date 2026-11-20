import Domain
import Foundation
import Imaging

/// Automatic masking's detector (FR-06 amendment): the pattern sweep over a stored capture. The
/// pixels are read inside Imaging; this adapter sees only the rectangles it returns.
@MainActor
public final class LiveSensitiveText: SensitiveTextService {
    private let store: ImageStore
    private let scanner = SensitiveTextScanner()
    private static let languages = [Locale.Language(identifier: "en-US"), Locale.Language(identifier: "pt-BR")]

    public init(store: ImageStore) {
        self.store = store
    }

    public func sensitiveRegions(in asset: ImageAssetInfo) async throws -> [PixelRect] {
        let pixelsPerPoint: Double =
            if case .captured(let geometry) = asset.origin { geometry.pointPixelScale } else { 1 }
        let regions = try await scanner.sensitiveRegions(
            of: asset.id, in: store, pixelsPerPoint: pixelsPerPoint, languages: Self.languages)
        // The scanner returns whole-pixel rectangles; rounding only drops floating-point noise.
        return regions.map {
            PixelRect(
                x: Int($0.rect.minX.rounded()), y: Int($0.rect.minY.rounded()), width: Int($0.rect.width.rounded()),
                height: Int($0.rect.height.rounded()))
        }
    }
}
