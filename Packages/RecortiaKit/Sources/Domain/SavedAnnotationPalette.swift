import Foundation

/// Explicitly saved annotation stroke colors; never image pixels or automatic recent colors.
public struct SavedAnnotationPalette: Hashable, Sendable, Codable {
    public static let maxColors = 12
    public private(set) var colors: [RGBA] = []

    public init() {}

    public func contains(_ color: RGBA) -> Bool {
        colors.contains(color.withAlpha(255))
    }

    @discardableResult
    public mutating func insert(_ color: RGBA) -> Bool {
        let opaque = color.withAlpha(255)
        guard colors.count < Self.maxColors, !colors.contains(opaque) else { return false }
        colors.append(opaque)
        return true
    }

    @discardableResult
    public mutating func remove(_ color: RGBA) -> Bool {
        guard let index = colors.firstIndex(of: color.withAlpha(255)) else { return false }
        colors.remove(at: index)
        return true
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        var container = try decoder.unkeyedContainer()
        let oversized = DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "A saved palette can contain at most 12 colors."))
        if let count = container.count, count > Self.maxColors { throw oversized }
        while !container.isAtEnd {
            guard container.currentIndex < Self.maxColors else { throw oversized }
            insert(try container.decode(RGBA.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for color in colors { try container.encode(color) }
    }
}
