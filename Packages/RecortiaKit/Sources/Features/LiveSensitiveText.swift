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
        let regions = try await scanner.sensitiveRegions(
            of: asset.id, in: store, pixelsPerPoint: Self.pixelsPerPoint(of: asset.origin), languages: Self.languages)
        // The scanner returns whole-pixel rectangles; rounding only drops floating-point noise.
        return regions.map {
            PixelRect(
                x: Int($0.rect.minX.rounded()), y: Int($0.rect.minY.rounded()), width: Int($0.rect.width.rounded()),
                height: Int($0.rect.height.rounded()))
        }
    }

    /// The density the sweep is laid out for: a capture's and a scrolling capture's own; an opened
    /// or pasted image records none, so it is read as 1, the slower sweep that upsamples more.
    static func pixelsPerPoint(of origin: AssetOrigin) -> Double {
        switch origin {
        case .captured(let geometry): geometry.pointPixelScale
        case .scrollCapture(_, let scale): scale
        case .imported, .pasted: 1
        }
    }
}
