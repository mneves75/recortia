import Foundation

/// The ratio a framed output keeps (FR-13). Presets are named by their ratio only.
public enum FramingAspect: String, Hashable, Sendable, Codable, CaseIterable {
    case free
    case square
    case portrait4x5
    case landscape16x9
    case portrait9x16
    case landscape3x2

    /// Width and height of the ratio in lowest terms; nil for Free.
    public var ratio: (width: Int, height: Int)? {
        switch self {
        case .free: nil
        case .square: (1, 1)
        case .portrait4x5: (4, 5)
        case .landscape16x9: (16, 9)
        case .portrait9x16: (9, 16)
        case .landscape3x2: (3, 2)
        }
    }
}

/// Where the content sits in the framed output (FR-13), in output pixels.
public struct OutputFrame: Hashable, Sendable {
    public let pixelSize: PixelSize
    /// The content's top-left corner, before any balance shift.
    public let contentOriginX: Double
    public let contentOriginY: Double

    public init(pixelSize: PixelSize, contentOriginX: Double, contentOriginY: Double) {
        self.pixelSize = pixelSize
        self.contentOriginX = contentOriginX
        self.contentOriginY = contentOriginY
    }
}

extension Presentation {
    /// A saved framing stays within the inspector's ranges and uses only finite values.
    public var validSavedFraming: Presentation? {
        let range = 0.0...512
        guard range.contains(padding), range.contains(cornerRadius),
            border?.isValid != false, watermark?.isValid != false
        else { return nil }
        if let shadow {
            guard shadow.radius.isFinite, shadow.radius >= 0, shadow.offsetY.isFinite, shadow.opacity.isFinite else {
                return nil
            }
        }
        if case .linearGradient(_, _, let angle) = background, !angle.isFinite { return nil }
        return self
    }

    /// The built-in background swatches: six solid colours, then four gradients.
    public static let backgroundSwatches: [Background] = [
        .solid(RGBA(r: 255, g: 255, b: 255)),
        .solid(RGBA(r: 229, g: 229, b: 234)),
        .solid(RGBA(r: 72, g: 72, b: 74)),
        .solid(RGBA(r: 28, g: 28, b: 30)),
        .solid(RGBA(r: 10, g: 132, b: 255)),
        .solid(RGBA(r: 48, g: 209, b: 88)),
        .linearGradient(from: RGBA(r: 99, g: 99, b: 102), to: RGBA(r: 44, g: 44, b: 46), angleDegrees: 135),
        .linearGradient(from: RGBA(r: 100, g: 210, b: 255), to: RGBA(r: 10, g: 132, b: 255), angleDegrees: 135),
        .linearGradient(from: RGBA(r: 255, g: 214, b: 10), to: RGBA(r: 255, g: 69, b: 58), angleDegrees: 135),
        .radialGradient(center: RGBA(r: 242, g: 242, b: 247), edge: RGBA(r: 142, g: 142, b: 147)),
    ]
}
