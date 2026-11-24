import AppKit
import CoreText
import Domain
import Testing

@testable import Imaging

// Independent acceptance review of train T2, F-1. The Core Text path refuses a created font whose
// PostScript name differs from the matched descriptor's (`mismatchedFont`). A system font that
// changes optical variant with size would then fail ordinary text at some sizes, which the
// existing comparison (11 sizes) could miss. This sweeps every editor font size, in halves, and
// the export scales applied to them.
@Suite("T2 review: designed fonts resolve at every editor and export size")
struct T2FontSizeSweepTests {
    static let editorSizes: [Double] = stride(from: 8.0, through: 200.0, by: 0.5).map { $0 }
    /// Export scale range is 0.1...8; these sizes are what rendering asks for at its extremes.
    static let scaledSizes: [Double] = [0.8, 1, 1.5, 2, 3, 4.5, 6, 7, 250, 400, 800, 1200, 1600]

    @Test(
        "Rounded and monospaced fonts resolve to their design at every size",
        arguments: [TextAppearance.rounded, .monospaced, .roundedBoxed, .monospacedBoxed])
    func designedFontsAtEverySize(appearance: TextAppearance) throws {
        var failures: [String] = []
        for size in Self.editorSizes + Self.scaledSizes {
            do {
                let font = try TextLayout.nativeFont(for: appearance, size: size)
                let traits = CTFontGetSymbolicTraits(font as CTFont)
                let isMono = traits.contains(.traitMonoSpace)
                switch appearance {
                case .monospaced, .monospacedBoxed:
                    if !isMono { failures.append("\(size): \(font.fontName) is not monospaced") }
                default:
                    if isMono || !font.fontName.localizedCaseInsensitiveContains("rounded") {
                        failures.append("\(size): \(font.fontName) is not the rounded design")
                    }
                }
                if abs(font.pointSize - size) > 0.001 { failures.append("\(size): got \(font.pointSize) pt") }
            } catch {
                failures.append("\(size): \(error)")
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(12))")
    }

    // Control: the same checks reject a font of the wrong design, so a pass above is meaningful.
    @Test("The design checks reject the standard system font")
    func controlRejectsStandardFont() {
        let font = NSFont.systemFont(ofSize: 13)
        #expect(!CTFontGetSymbolicTraits(font as CTFont).contains(.traitMonoSpace))
        #expect(!font.fontName.localizedCaseInsensitiveContains("rounded"))
    }
}
