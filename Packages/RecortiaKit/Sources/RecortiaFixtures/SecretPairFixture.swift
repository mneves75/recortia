import CoreGraphics
import CoreText
import Foundation

/// Errors from synthetic fixture generation. Fixtures never read files or real screenshots.
public enum FixtureError: Error, Equatable, Sendable {
    case contextUnavailable
    case imageUnavailable
    case invalidArgument
    case encodingFailed
}

/// SplitMix64: a tiny, fully specified generator so every fixture is reproducible from its seed.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
}

/// An integer pixel rectangle with a top-left origin.
public struct FixtureRect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    public func contains(x px: Int, y py: Int) -> Bool { px >= x && px < maxX && py >= y && py < maxY }
}

/// Two same-size images that are byte-identical outside `secret` and radically different inside it:
/// `a` holds dark text on white, `b` holds seeded random noise (including random alpha).
public struct SecretPair: Sendable {
    public let a: CGImage
    public let b: CGImage
    public let secret: FixtureRect
    public let width: Int
    public let height: Int
}

public enum SecretPairFixture {
    /// Builds a pair whose shared background is a seeded pattern of colored blocks and gradients.
    /// With `translucentBackground`, background blocks use alpha values 0, 64, 160, and 255.
    public static func make(
        width: Int, height: Int, secret: FixtureRect, seed: UInt64, translucentBackground: Bool = false
    ) throws(FixtureError) -> SecretPair {
        guard width > 0, height > 0, secret.width > 0, secret.height > 0, secret.x >= 0, secret.y >= 0,
            secret.maxX <= width, secret.maxY <= height
        else { throw FixtureError.invalidArgument }

        var rng = SeededGenerator(seed: seed)
        let base = backgroundBytes(width: width, height: height, rng: &rng, translucent: translucentBackground)

        var noisy = base
        for y in secret.y..<secret.maxY {
            for x in secret.x..<secret.maxX {
                let alpha = rng.next() % 2 == 0 ? UInt8(255) : rng.byte()
                let i = (y * width + x) * 4
                noisy[i] = premultiply(rng.byte(), alpha)
                noisy[i + 1] = premultiply(rng.byte(), alpha)
                noisy[i + 2] = premultiply(rng.byte(), alpha)
                noisy[i + 3] = alpha
            }
        }

        let baseImage = try ChartFixture.image(width: width, height: height, premultipliedRGBA: base)
        let textImage = try drawText(over: baseImage, secret: secret)
        let noiseImage = try ChartFixture.image(width: width, height: height, premultipliedRGBA: noisy)
        return SecretPair(a: textImage, b: noiseImage, secret: secret, width: width, height: height)
    }

    private static func premultiply(_ value: UInt8, _ alpha: UInt8) -> UInt8 {
        UInt8((Int(value) * Int(alpha) + 127) / 255)
    }

    private static func backgroundBytes(
        width: Int, height: Int, rng: inout SeededGenerator, translucent: Bool
    ) -> [UInt8] {
        let block = 8
        let columns = (width + block - 1) / block
        let rows = (height + block - 1) / block
        var blockColors: [[UInt8]] = []
        let alphas: [UInt8] = [0, 64, 160, 255]
        for _ in 0..<(columns * rows) {
            let alpha = translucent ? alphas[Int(rng.next() % 4)] : 255
            blockColors.append([rng.byte(), rng.byte(), rng.byte(), alpha])
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = blockColors[(y / block) * columns + x / block]
                let alpha = color[3]
                let gradient = UInt8((x * 255) / max(1, width - 1))
                let i = (y * width + x) * 4
                bytes[i] = premultiply(color[0], alpha)
                bytes[i + 1] = premultiply(UInt8((Int(color[1]) + Int(gradient)) / 2), alpha)
                bytes[i + 2] = premultiply(color[2], alpha)
                bytes[i + 3] = alpha
            }
        }
        return bytes
    }

    private static func drawText(over image: CGImage, secret: FixtureRect) throws(FixtureError) -> CGImage {
        let width = image.width, height = image.height
        guard let context = ChartFixture.context(width: width, height: height) else {
            throw FixtureError.contextUnavailable
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Core Graphics has a bottom-left origin; the fixture rect is top-left.
        let clip = CGRect(x: secret.x, y: height - secret.maxY, width: secret.width, height: secret.height)
        context.clip(to: clip)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(clip)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(6, Double(secret.height) * 0.6), nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
        ]
        guard
            let string = CFAttributedStringCreate(
                nil, "4111 1111 SECRET" as CFString, attributes as CFDictionary)
        else { throw FixtureError.imageUnavailable }
        let line = CTLineCreateWithAttributedString(string)
        context.textPosition = CGPoint(x: clip.minX + 1, y: clip.minY + clip.height * 0.25)
        CTLineDraw(line, context)
        guard let result = context.makeImage() else { throw FixtureError.imageUnavailable }
        return result
    }
}
