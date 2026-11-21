import Domain
import Foundation
import Testing

// Failure modes (FR-11, A-7): a copied colour string that is wrong, locale-dependent, or drops
// alpha; an OKLCH value off Ottosson's published reference; a contrast ratio or pass mark that
// disagrees with the W3C definition, or shows a passing number for a failing pair.
@Suite("Colour formats, OKLab and WCAG contrast (FR-11)")
struct ColorFormatTests {
    private static let navy = RGBA(r: 26, g: 43, b: 60)

    @Test("Every format of an opaque colour, in a fixed C-style notation")
    func opaqueFormats() {
        let expected: [ColorFormat: String] = [
            .hex: "#1A2B3C",
            .cssRGB: "rgb(26, 43, 60)",
            .normalizedRGB: "0.102, 0.169, 0.235",
            .swiftUI: "Color(red: 0.102, green: 0.169, blue: 0.235)",
            .uiKit: "UIColor(red: 0.102, green: 0.169, blue: 0.235, alpha: 1)",
            .android: "0xFF1A2B3C",
            .oklch: "oklch(28.26% 0.0388 249.34)",
        ]
        #expect(Set(expected.keys) == Set(ColorFormat.allCases))
        for format in ColorFormat.allCases {
            #expect(Self.navy.formatted(format) == expected[format], "\(format)")
        }
    }

    @Test("A translucent colour carries its alpha in every format")
    func translucentFormats() {
        let color = Self.navy.withAlpha(128)
        let expected: [ColorFormat: String] = [
            .hex: "#1A2B3C80",
            .cssRGB: "rgba(26, 43, 60, 0.502)",
            .normalizedRGB: "0.102, 0.169, 0.235, 0.502",
            .swiftUI: "Color(red: 0.102, green: 0.169, blue: 0.235, opacity: 0.502)",
            .uiKit: "UIColor(red: 0.102, green: 0.169, blue: 0.235, alpha: 0.502)",
            .android: "0x801A2B3C",
            .oklch: "oklch(28.26% 0.0388 249.34 / 0.502)",
        ]
        for format in ColorFormat.allCases {
            #expect(color.formatted(format) == expected[format], "\(format)")
        }
    }

    @Test("Edge values: alpha 0, black and white, with no negative zero or powerless hue")
    func edgeFormats() {
        let cases: [(RGBA, ColorFormat, String)] = [
            (.clear, .hex, "#00000000"), (.clear, .cssRGB, "rgba(0, 0, 0, 0)"),
            (.clear, .normalizedRGB, "0, 0, 0, 0"), (.clear, .swiftUI, "Color(red: 0, green: 0, blue: 0, opacity: 0)"),
            (.clear, .uiKit, "UIColor(red: 0, green: 0, blue: 0, alpha: 0)"), (.clear, .android, "0x00000000"),
            (.clear, .oklch, "oklch(0% 0 0 / 0)"),
            (.white, .normalizedRGB, "1, 1, 1"), (.white, .swiftUI, "Color(red: 1, green: 1, blue: 1)"),
            (.white, .android, "0xFFFFFFFF"), (.white, .oklch, "oklch(100% 0 0)"),
            (.black, .oklch, "oklch(0% 0 0)"), (.black, .cssRGB, "rgb(0, 0, 0)"),
            (RGBA(r: 119, g: 119, b: 119), .oklch, "oklch(56.93% 0 0)"),
        ]
        for (color, format, string) in cases {
            #expect(color.formatted(format) == string, "\(color) \(format)")
        }
    }

    @Test("Unit components round half away to three decimals and drop trailing zeros")
    func unitRounding() {
        // 1/255 = 0.00392 rounds up, 254/255 = 0.99608 rounds up, 51/255 is exactly 0.2.
        #expect(RGBA(r: 1, g: 254, b: 51).formatted(.normalizedRGB) == "0.004, 0.996, 0.2")
        #expect(RGBA(r: 0, g: 0, b: 0, a: 254).formatted(.cssRGB) == "rgba(0, 0, 0, 0.996)")
    }

    // Björn Ottosson, "A perceptual color space for image processing" (2020, matrices updated
    // 2021-01-25), table of example XYZ and Oklab pairs, rounded to three decimals. Converted to
    // linear sRGB with the inverse of the IEC 61966-2-1 sRGB-to-XYZ matrix (D65), so the product's
    // own linear-sRGB matrices are what is tested.
    @Test(
        "OKLab matches Ottosson's published XYZ/Oklab example pairs",
        arguments: [
            ([0.950, 1.000, 1.089], [1.000, 0.000, 0.000]),
            ([1.000, 0.000, 0.000], [0.450, 1.236, -0.019]),
            ([0.000, 1.000, 0.000], [0.922, -0.671, 0.263]),
            ([0.000, 0.000, 1.000], [0.153, -1.415, -0.449]),
        ])
    func ottossonPairs(xyz: [Double], lab: [Double]) {
        let toLinear: [[Double]] = [
            [3.2409699419045226, -1.5373831775700939, -0.4986107602930034],
            [-0.9692436362808796, 1.8759675015077202, 0.0415550574071756],
            [0.05563007969699366, -0.20397695888897652, 1.0569715142428786],
        ]
        let rgb = toLinear.map { row in zip(row, xyz).map(*).reduce(0, +) }
        let result = OKLab(linearRed: rgb[0], green: rgb[1], blue: rgb[2])
        // Half a unit of the table's third decimal plus the published matrices' own difference.
        #expect(abs(result.lightness - lab[0]) < 0.001)
        #expect(abs(result.a - lab[1]) < 0.001)
        #expect(abs(result.b - lab[2]) < 0.001)
    }

    @Test("sRGB primaries in OKLCH")
    func primaries() {
        #expect(RGBA(r: 255, g: 0, b: 0).formatted(.oklch) == "oklch(62.8% 0.2577 29.23)")
        #expect(RGBA(r: 0, g: 255, b: 0).formatted(.oklch) == "oklch(86.64% 0.2948 142.5)")
        // A negative atan2 hue wraps into 0..<360.
        #expect(RGBA(r: 0, g: 0, b: 255).formatted(.oklch) == "oklch(45.2% 0.3132 264.05)")
    }

    @Test("sRGB decoding uses the 0.04045 threshold of IEC 61966-2-1, not WCAG 2.0's 0.03928")
    func transferThreshold() {
        // 0.04 lies between the two thresholds: the sRGB threshold keeps it on the linear segment.
        #expect(RGBA.linearComponent(0.04) == 0.04 / 12.92)
        #expect(RGBA.linearComponent(0.04045) == 0.04045 / 12.92)
        #expect(RGBA.linearComponent(0.0405) == pow((0.0405 + 0.055) / 1.055, 2.4))
        #expect(RGBA.linearComponent(0) == 0)
        #expect(RGBA.linearComponent(1) == 1)
    }

    @Test("Relative luminance at the edges and for mid grey")
    func luminance() {
        #expect(RGBA.black.relativeLuminance == 0)
        #expect(abs(RGBA.white.relativeLuminance - 1) < 1e-12)
        #expect(abs(RGBA(r: 119, g: 119, b: 119).relativeLuminance - 0.184475) < 1e-6)
        // Rec. 709 weights: pure green outweighs red, which outweighs blue.
        #expect(abs(RGBA(r: 0, g: 255, b: 0).relativeLuminance - 0.7152) < 1e-12)
        #expect(abs(RGBA(r: 0, g: 0, b: 255).relativeLuminance - 0.0722) < 1e-12)
    }

    @Test("WCAG 2 contrast for published pairs, in either order")
    func publishedPairs() throws {
        let max = try #require(ContrastRatio(foreground: .black, background: .white))
        #expect(max.ratio == 21)
        #expect(try #require(ContrastRatio(foreground: .white, background: .white)).ratio == 1)

        let grey = RGBA(r: 0x77, g: 0x77, b: 0x77)
        let low = try #require(ContrastRatio(foreground: grey, background: .white))
        #expect(abs(low.ratio - 4.4781) < 0.0001)
        #expect(ContrastRatio(foreground: .white, background: grey)?.ratio == low.ratio)
        #expect(!low.passes(.aa, largeText: false) && low.passes(.aa, largeText: true))
        #expect(!low.passes(.aaa, largeText: false) && !low.passes(.aaa, largeText: true))

        let aa = try #require(ContrastRatio(foreground: RGBA(r: 0x76, g: 0x76, b: 0x76), background: .white))
        #expect(abs(aa.ratio - 4.5422) < 0.0001)
        #expect(aa.passes(.aa, largeText: false) && aa.passes(.aaa, largeText: true))
        #expect(!aa.passes(.aaa, largeText: false))

        let aaa = try #require(ContrastRatio(foreground: RGBA(r: 0x59, g: 0x59, b: 0x59), background: .white))
        #expect(aaa.passes(.aaa, largeText: false))
        let belowAAA = try #require(ContrastRatio(foreground: RGBA(r: 0x5A, g: 0x5A, b: 0x5A), background: .white))
        #expect(!belowAAA.passes(.aaa, largeText: false))

        // 3:1 for large text: #949494 passes at 3.03, #959595 fails at 2.995.
        #expect(
            ContrastRatio(foreground: RGBA(r: 0x94, g: 0x94, b: 0x94), background: .white)?.passes(.aa, largeText: true)
                == true)
        #expect(
            ContrastRatio(foreground: RGBA(r: 0x95, g: 0x95, b: 0x95), background: .white)?.passes(.aa, largeText: true)
                == false)
    }

    @Test("The shown ratio is truncated so a failing pair never reads as a threshold")
    func displayedRatio() throws {
        #expect(
            try #require(ContrastRatio(foreground: RGBA(r: 0x77, g: 0x77, b: 0x77), background: .white)).shownRatio
                == 4.47)
        #expect(
            try #require(ContrastRatio(foreground: RGBA(r: 0x95, g: 0x95, b: 0x95), background: .white)).shownRatio
                == 2.99)
        #expect(try #require(ContrastRatio(foreground: .black, background: .white)).shownRatio == 21)
    }

    @Test("Contrast needs two opaque colours")
    func translucentContrast() {
        #expect(ContrastRatio(foreground: .clear, background: .white) == nil)
        #expect(ContrastRatio(foreground: .black, background: RGBA.white.withAlpha(254)) == nil)
    }

    @Test("The preferred format defaults to HEX and survives a round trip; older blobs decode")
    func preference() throws {
        #expect(Preferences().colorFormat == .hex)
        var stored = Preferences()
        stored.colorFormat = .oklch
        let data = try JSONEncoder().encode(stored)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["colorFormatChoice"] as? String == "oklch")
        #expect(try JSONDecoder().decode(Preferences.self, from: data).colorFormat == .oklch)
        object["colorFormatChoice"] = nil
        let older = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Preferences.self, from: older).colorFormat == .hex)
    }
}
