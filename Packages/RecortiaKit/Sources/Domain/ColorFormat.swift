import Foundation

/// How the colour picker copies a colour as text (FR-11, A-7). Every format is written with `.`
/// decimals whatever the locale, because each one is meant to be pasted into code or CSS.
public enum ColorFormat: String, Hashable, Sendable, Codable, CaseIterable {
    /// `#RRGGBB`, or `#RRGGBBAA` when translucent (CSS Color 4).
    case hex
    /// `rgb(26, 43, 60)`, or `rgba(26, 43, 60, 0.502)` when translucent.
    case cssRGB
    /// `0.102, 0.169, 0.235`, with a fourth alpha component when translucent.
    case normalizedRGB
    /// SwiftUI `Color(red:green:blue:)` (its default colour space is sRGB), `opacity:` when translucent.
    case swiftUI
    /// UIKit `UIColor(red:green:blue:alpha:)`.
    case uiKit
    /// Android `0xAARRGGBB`.
    case android
    /// CSS `oklch(L% C H)`, `/ alpha` when translucent.
    case oklch
}

extension RGBA {
    /// This colour as `format` text.
    public func formatted(_ format: ColorFormat) -> String {
        let alpha = isOpaque ? nil : Self.decimal(Double(a) / 255, digits: 3)
        let units = [r, g, b].map { Self.decimal(Double($0) / 255, digits: 3) }
        switch format {
        case .hex:
            return isOpaque ? hex : hex + String(format: "%02X", a)
        case .cssRGB:
            return alpha.map { "rgba(\(r), \(g), \(b), \($0))" } ?? "rgb(\(r), \(g), \(b))"
        case .normalizedRGB:
            return (units + (alpha.map { [$0] } ?? [])).joined(separator: ", ")
        case .swiftUI:
            let opacity = alpha.map { ", opacity: \($0)" } ?? ""
            return "Color(red: \(units[0]), green: \(units[1]), blue: \(units[2])\(opacity))"
        case .uiKit:
            return "UIColor(red: \(units[0]), green: \(units[1]), blue: \(units[2]), alpha: \(alpha ?? "1"))"
        case .android:
            return String(format: "0x%02X%02X%02X%02X", a, r, g, b)
        case .oklch:
            let lab = OKLab(self)
            let chroma = Self.decimal((lab.a * lab.a + lab.b * lab.b).squareRoot(), digits: 4)
            // An achromatic colour has no hue (CSS calls it powerless); 0 keeps the string stable.
            var hue = "0"
            if chroma != "0" {
                let degrees = atan2(lab.b, lab.a) * 180 / .pi
                hue = Self.decimal(degrees < 0 ? degrees + 360 : degrees, digits: 2)
                if hue == "360" { hue = "0" }
            }
            let lightness = Self.decimal(lab.lightness * 100, digits: 2)
            return "oklch(\(lightness)% \(chroma) \(hue)\(alpha.map { " / \($0)" } ?? ""))"
        }
    }

    /// `value` rounded half away from zero to at most `digits` decimals, trailing zeros dropped,
    /// with `.` as the separator and never `-0`. `digits` is 0...4 and `value` bounded (a colour
    /// component, OKLCH lightness in percent, chroma or hue), so the scaled value fits an Int.
    static func decimal(_ value: Double, digits: Int) -> String {
        var power = 1
        for _ in 0..<digits { power *= 10 }
        guard let scaled = Int(exactly: (value * Double(power)).rounded(.toNearestOrAwayFromZero)) else {
            return "0"
        }
        let magnitude = scaled.magnitude, unit = UInt(power)
        var text = "\(magnitude / unit)"
        if magnitude % unit > 0 {
            var fraction = String(magnitude % unit)
            fraction = String(repeating: "0", count: digits - fraction.count) + fraction
            while fraction.hasSuffix("0") { fraction.removeLast() }
            text += "." + fraction
        }
        return scaled < 0 ? "-" + text : text
    }

    /// An encoded sRGB component (0...1) decoded to linear light. The threshold is 0.04045, as in
    /// the sRGB standard (IEC 61966-2-1) and WCAG 2.1 and later, not the 0.03928 that WCAG 2.0
    /// printed; for 8-bit input the two choose the same branch for every value.
    public static func linearComponent(_ encoded: Double) -> Double {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    /// Relative luminance with the Rec. 709 weights of the sRGB primaries, as WCAG 2 defines it;
    /// alpha is ignored.
    public var relativeLuminance: Double {
        0.2126 * Self.linearComponent(Double(r) / 255) + 0.7152 * Self.linearComponent(Double(g) / 255)
            + 0.0722 * Self.linearComponent(Double(b) / 255)
    }
}

/// A colour in Björn Ottosson's Oklab space, from "A perceptual color space for image processing"
/// (https://bottosson.github.io/posts/oklab/, matrices updated 2021-01-25; public domain or MIT).
public struct OKLab: Hashable, Sendable {
    public let lightness: Double
    public let a: Double
    public let b: Double

    /// The encoded sRGB colour's Oklab value; alpha is ignored.
    public init(_ color: RGBA) {
        self.init(
            linearRed: RGBA.linearComponent(Double(color.r) / 255),
            green: RGBA.linearComponent(Double(color.g) / 255),
            blue: RGBA.linearComponent(Double(color.b) / 255))
    }

    /// Ottosson's `linear_srgb_to_oklab`, coefficients copied from the post. Out-of-gamut (negative)
    /// components are allowed: the cube root keeps their sign.
    public init(linearRed red: Double, green: Double, blue: Double) {
        let l = 0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue
        let m = 0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue
        let s = 0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        lightness = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    }
}

/// The WCAG 2.x contrast ratio of two opaque sRGB colours: (L1 + 0.05) / (L2 + 0.05), lighter
/// over darker, from 1 to 21. APCA is deliberately not offered (program-2026-11 decisions).
public struct ContrastRatio: Hashable, Sendable {
    public enum Level: Hashable, Sendable, CaseIterable {
        case aa
        case aaa
    }

    public let ratio: Double

    /// Nil unless both colours are opaque: WCAG 2 defines contrast between opaque colours only.
    public init?(foreground: RGBA, background: RGBA) {
        guard foreground.isOpaque, background.isOpaque else { return nil }
        let one = foreground.relativeLuminance, two = background.relativeLuminance
        ratio = (max(one, two) + 0.05) / (min(one, two) + 0.05)
    }

    /// The ratio truncated to two decimals, so a pair that fails a threshold never shows it
    /// (#777777 on white is 4.478…, shown 4.47, and fails AA for normal text).
    public var shownRatio: Double { (ratio * 100).rounded(.down) / 100 }

    /// WCAG 2 success criteria 1.4.3 (AA: 4.5, large text 3) and 1.4.6 (AAA: 7, large text 4.5),
    /// compared with the unrounded ratio.
    public func passes(_ level: Level, largeText: Bool) -> Bool {
        let threshold: Double =
            switch (level, largeText) {
            case (.aa, false): 4.5
            case (.aa, true): 3
            case (.aaa, false): 7
            case (.aaa, true): 4.5
            }
        return ratio >= threshold
    }
}
