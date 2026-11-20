import CoreGraphics
import CoreText
import Foundation

/// Synthetic screens with e-mail addresses and phone numbers planted at known pixel rectangles,
/// plus look-alike decoys (dates, versions, IDs, amounts...) that must stay unmasked. Every address
/// and number is invented (example domains, 555-01xx and fictional subscriber digits). Deterministic.
public enum SensitiveScreen {
    public enum Layout: String, Sendable, CaseIterable {
        /// One sentence-like line per row: label, item, decoy, prose.
        case singleColumn
        /// A dense table repeated across the width: name, e-mail, phone, date, amount, decoy.
        case denseColumns
    }

    public enum Kind: String, Sendable, CaseIterable {
        case email
        case phone
    }

    public struct Planted: Sendable {
        public let kind: Kind
        /// Which notation the item uses ("br-mobile", "nanp", "email-plus"...).
        public let format: String
        public let text: String
        /// Pixels the item's glyphs touch (ink bounds rounded outward), image pixels, top-left origin.
        public let rect: CGRect
    }

    public struct Decoy: Sendable {
        public let category: String
        public let text: String
        public let rect: CGRect
    }

    public struct Screen: Sendable {
        public let id: String
        public let image: CGImage
        public let scale: Int
        public let pointSize: Double
        public let theme: TextCorpus.Theme
        public let language: TextCorpus.Language
        public let layout: Layout
        public let planted: [Planted]
        public let decoys: [Decoy]
    }

    public static func render(
        widthPoints: Int, heightPoints: Int, scale: Int, pointSize: Double, theme: TextCorpus.Theme,
        language: TextCorpus.Language, layout: Layout
    ) throws -> Screen {
        let width = widthPoints * scale, height = heightPoints * scale
        let pixelSize = CGFloat(pointSize) * CGFloat(scale)
        guard let font = CTFontCreateUIFontForLanguage(.system, pixelSize, nil) else {
            throw TextCorpus.RenderError.fontUnavailable
        }
        let context = try makeContext(width: width, height: height, theme: theme)
        var canvas = Canvas(
            context: context, font: font, height: CGFloat(height),
            foreground: theme == .light ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 0.92, alpha: 1))
        let margin = (20 * CGFloat(scale)).rounded()
        let lineHeight = ((canvas.ascent + canvas.descent + CTFontGetLeading(font)) * 1.35).rounded(.up)
        let id =
            "\(widthPoints)x\(heightPoints)@\(scale)x-\(Int(pointSize))pt-\(theme.rawValue)-"
            + "\(language.rawValue)-\(layout.rawValue)"
        // FNV-1a of the id: different content per screen, identical across runs.
        let seed = id.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        var generator = Generator(language: language, seed: seed)
        switch layout {
        case .singleColumn:
            var top = margin
            var row = 0
            while top + lineHeight <= CGFloat(height) - margin {
                canvas.drawRow(
                    generator.sentence(row: row), x: margin, top: top, maxWidth: CGFloat(width) - 2 * margin)
                top += lineHeight
                row += 1
            }
        case .denseColumns:
            let gap = (pixelSize * 1.5).rounded()
            var sampler = Generator(language: language, seed: seed)
            let samples = (0..<24).map { sampler.tableRow(row: $0) }
            var columnWidths = (0..<samples[0].count).map { column in
                samples.map { canvas.width(of: $0[column].text) }.max() ?? 0
            }
            // Drop trailing columns that do not fit even once.
            while columnWidths.count > 1,
                columnWidths.reduce(0, +) + gap * CGFloat(columnWidths.count - 1)
                    > CGFloat(width) - 2 * margin
            {
                columnWidths.removeLast()
            }
            let groupWidth = columnWidths.reduce(0, +) + gap * CGFloat(columnWidths.count)
            let groups = max(1, Int((CGFloat(width) - 2 * margin + gap) / groupWidth))
            var top = margin
            var row = 0
            while top + lineHeight <= CGFloat(height) - margin {
                var x = margin
                for _ in 0..<groups {
                    let cells = generator.tableRow(row: row)
                    for (column, columnWidth) in columnWidths.enumerated() {
                        canvas.drawRow([cells[column]], x: x, top: top, maxWidth: columnWidth + 1)
                        x += columnWidth + gap
                    }
                    row += 1
                }
                top += lineHeight
            }
        }
        guard let image = context.makeImage() else { throw TextCorpus.RenderError.contextUnavailable }
        return Screen(
            id: id, image: image, scale: scale, pointSize: pointSize, theme: theme, language: language, layout: layout,
            planted: canvas.planted, decoys: canvas.decoys)
    }

    /// One planted item drawn alone with its left edge at `x` and its line top at `top` (image
    /// pixels), on an otherwise empty screen: for placing the same item across a tile seam.
    public static func renderItem(
        _ text: String, kind: Kind, widthPoints: Int, heightPoints: Int, scale: Int, pointSize: Double,
        x: CGFloat, top: CGFloat, theme: TextCorpus.Theme = .light
    ) throws -> Screen {
        let width = widthPoints * scale, height = heightPoints * scale
        guard let font = CTFontCreateUIFontForLanguage(.system, CGFloat(pointSize) * CGFloat(scale), nil) else {
            throw TextCorpus.RenderError.fontUnavailable
        }
        let context = try makeContext(width: width, height: height, theme: theme)
        var canvas = Canvas(
            context: context, font: font, height: CGFloat(height),
            foreground: theme == .light ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 0.92, alpha: 1))
        canvas.drawRow(
            [Segment(text: text, role: .planted(kind, format: "item"))], x: x, top: top,
            maxWidth: .greatestFiniteMagnitude)
        guard let image = context.makeImage() else { throw TextCorpus.RenderError.contextUnavailable }
        return Screen(
            id: "item-\(widthPoints)x\(heightPoints)@\(scale)x-\(Int(pointSize))pt-x\(Int(x))", image: image,
            scale: scale,
            pointSize: pointSize, theme: theme, language: .english, layout: .singleColumn, planted: canvas.planted,
            decoys: [])
    }

    // MARK: - Drawing

    /// A piece of a row. `role` decides whether its rectangle is recorded as planted or as a decoy.
    struct Segment {
        enum Role {
            case text
            case planted(Kind, format: String)
            case decoy(String)
        }
        let text: String
        let role: Role
    }

    private struct Canvas {
        let context: CGContext
        let font: CTFont
        let height: CGFloat
        let foreground: CGColor
        let ascent: CGFloat
        let descent: CGFloat
        var planted: [Planted] = []
        var decoys: [Decoy] = []

        init(context: CGContext, font: CTFont, height: CGFloat, foreground: CGColor) {
            self.context = context
            self.font = font
            self.height = height
            self.foreground = foreground
            ascent = CTFontGetAscent(font)
            descent = CTFontGetDescent(font)
        }

        func line(_ text: String) -> CTLine {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground,
            ]
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        }

        func width(of text: String) -> CGFloat {
            CGFloat(CTLineGetTypographicBounds(line(text), nil, nil, nil))
        }

        /// Draws as many leading segments as fit in `maxWidth` (at least the first) and records the
        /// rectangles of planted items and decoys among them.
        mutating func drawRow(_ segments: [Segment], x: CGFloat, top: CGFloat, maxWidth: CGFloat) {
            var kept: [Segment] = []
            for segment in segments {
                let candidate = (kept + [segment]).map(\.text).joined()
                if !kept.isEmpty, width(of: candidate) > maxWidth { break }
                kept.append(segment)
            }
            let text = kept.map(\.text).joined()
            let ctLine = line(text)
            context.textPosition = CGPoint(x: x, y: height - top - ascent)
            CTLineDraw(ctLine, context)
            var offset = 0
            for segment in kept {
                let length = (segment.text as NSString).length
                defer { offset += length }
                // Ground truth is the ink: the segment's glyph image bounds, rounded outward to the
                // pixels it touches, at the segment's position in the line.
                let start = CTLineGetOffsetForStringIndex(ctLine, offset, nil)
                context.textPosition = .zero  // image bounds are offset by the text position
                let ink = CTLineGetImageBounds(line(segment.text), context)
                let baseline = top + ascent
                let rect = CGRect(
                    x: (x + start + ink.minX).rounded(.down), y: (baseline - ink.maxY).rounded(.down),
                    width: 0, height: 0
                ).union(CGPoint(x: (x + start + ink.maxX).rounded(.up), y: (baseline - ink.minY).rounded(.up)))
                switch segment.role {
                case .text: break
                case .planted(let kind, let format):
                    planted.append(Planted(kind: kind, format: format, text: segment.text, rect: rect))
                case .decoy(let category):
                    decoys.append(Decoy(category: category, text: segment.text, rect: rect))
                }
            }
        }
    }

    private static func makeContext(width: Int, height: Int, theme: TextCorpus.Theme) throws -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw TextCorpus.RenderError.contextUnavailable }
        context.setFillColor(theme == .light ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldSmoothFonts(false)
        return context
    }

    // MARK: - Content

    /// Deterministic invented content.
    struct Generator {
        let language: TextCorpus.Language
        private var state: UInt64

        init(language: TextCorpus.Language, seed: UInt64) {
            self.language = language
            state = seed
        }

        private mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }

        private mutating func digits(_ count: Int) -> String {
            String((0..<count).map { _ in Character(String(next(10))) })
        }

        static let firstNames = ["ana", "bruno", "carla", "diego", "elisa", "felipe", "gabi", "heitor", "iris", "joao"]
        static let lastNames = ["silva", "souza", "lima", "costa", "rocha", "alves", "pereira", "martins", "gomes"]
        static let areaCodes = ["11", "21", "31", "41", "47", "51", "61", "71", "81", "85"]

        mutating func email() -> Segment {
            let first = Self.firstNames[next(Self.firstNames.count)]
            let last = Self.lastNames[next(Self.lastNames.count)]
            let domain = language == .english ? "example" : "exemplo"
            let formats: [(String, String)] = [
                ("email-dotted", "\(first).\(last)@\(domain).com\(language == .english ? "" : ".br")"),
                ("email-plus", "\(first)+news@\(domain).org"),
                ("email-short", "\(first)@\(domain).io"),
                ("email-underscore", "\(first)_\(last)\(next(90) + 10)@mail.\(domain).net"),
            ]
            let (format, text) = formats[next(formats.count)]
            return Segment(text: text, role: .planted(.email, format: format))
        }

        mutating func phone() -> Segment {
            let area = Self.areaCodes[next(Self.areaCodes.count)]
            let formats: [(String, String)] = [
                ("br-mobile", "(\(area)) 9\(digits(4))-\(digits(4))"),
                ("br-plus55", "+55 \(area) 9\(digits(4))-\(digits(4))"),
                ("br-landline", "(\(area)) 3\(digits(3))-\(digits(4))"),
                ("nanp", "(415) 555-01\(digits(2))"),
                ("nanp-plus1", "+1 212-555-01\(digits(2))"),
                ("intl-pt", "+351 912 \(digits(3)) \(digits(3))"),
                ("intl-uk", "+44 20 7946 0\(digits(3))"),
            ]
            let (format, text) = formats[next(formats.count)]
            return Segment(text: text, role: .planted(.phone, format: format))
        }

        mutating func decoy() -> Segment {
            let decoys: [(String, String)] = [
                ("git-remote", "git@github.com:org/repo\(next(9)).git"),
                ("version", "v1.\(next(9)).\(next(9)).\(next(90) + 10)"),
                ("date-iso", "2026-11-\(10 + next(19))"),
                ("date-br", "\(10 + next(19))/11/2026"),
                ("time", "\(10 + next(13)):\(10 + next(49)):\(10 + next(49))"),
                ("id", "#\(digits(11))"),
                ("amount", "R$ \(1 + next(9)).\(digits(3)),\(digits(2))"),
                ("ip", "192.168.\(next(255)).\(next(255))"),
                ("uuid", "550e8400-e29b-41d4-a716-\(digits(12))"),
                ("hex", "#\(String(format: "%06X", next(0xFF_FFFF)))"),
            ]
            let (category, text) = decoys[next(decoys.count)]
            return Segment(text: text, role: .decoy(category))
        }

        private var prose: [String] { language == .english ? TextCorpus.englishProse : TextCorpus.portugueseProse }

        /// Rows of label + item + decoy + prose, with a plain prose row every third row.
        mutating func sentence(row: Int) -> [Segment] {
            let line = prose[row % prose.count]
            if row % 3 == 2 { return [Segment(text: line, role: .text)] }
            let isEmail = next(2) == 0
            let label: String
            switch (language, isEmail) {
            case (.english, true): label = ["Email: ", "Write to ", "Contact "][next(3)]
            case (.english, false): label = ["Phone: ", "Call ", "Mobile "][next(3)]
            case (.portugueseBrazil, true): label = ["E-mail: ", "Escreva para ", "Contato "][next(3)]
            case (.portugueseBrazil, false): label = ["Telefone: ", "Ligue ", "Celular "][next(3)]
            }
            return [
                Segment(text: label, role: .text), isEmail ? email() : phone(), Segment(text: "  ", role: .text),
                decoy(), Segment(text: "  " + line, role: .text),
            ]
        }

        /// Name, e-mail, phone, date, amount, decoy.
        mutating func tableRow(row: Int) -> [Segment] {
            let name =
                Self.firstNames[next(Self.firstNames.count)].capitalized + " "
                + Self.lastNames[next(Self.lastNames.count)].capitalized
            return [
                Segment(text: name, role: .text), email(), phone(),
                Segment(text: "\(10 + next(19))/11/2026", role: .decoy("date-br")),
                Segment(text: "R$ \(next(9_000) + 100),\(digits(2))", role: .decoy("amount")), decoy(),
            ]
        }
    }
}

extension CGRect {
    fileprivate func union(_ point: CGPoint) -> CGRect {
        CGRect(x: minX, y: minY, width: max(0, point.x - minX), height: max(0, point.y - minY))
    }
}
