import Foundation

/// An 8-bit sRGB color with straight (non-premultiplied) alpha. Canonical v1 color (FR-11).
public struct RGBA: Hashable, Sendable, Codable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public var alpha: UInt8 { a }
    public var isOpaque: Bool { a == 255 }

    /// `#RRGGBB`, uppercase, alpha ignored.
    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

    public func withAlpha(_ alpha: UInt8) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }

    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let white = RGBA(r: 255, g: 255, b: 255)
    public static let red = RGBA(r: 229, g: 57, b: 53)
    public static let yellow = RGBA(r: 255, g: 214, b: 0)
    public static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
}
