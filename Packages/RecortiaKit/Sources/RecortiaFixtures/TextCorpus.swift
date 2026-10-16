import CoreGraphics
import CoreText
import Foundation

/// Synthetic OCR corpus (OCR-01): typed text rendered with the system UI fonts, with ground-truth
/// text and line rectangles. Deterministic on a given OS build; nothing is read from disk.
public enum TextCorpus {
    public static let version = 1

    public enum Language: String, Sendable, CaseIterable {
        case english = "en-US"
        case portugueseBrazil = "pt-BR"
    }

    public enum Theme: String, Sendable, CaseIterable {
        case light
        case dark
    }

    public enum Category: String, Sendable, CaseIterable {
        /// Plain sentences at readable Retina sizes: the "clean typed-text" subset.
        case prose
        /// Prose at non-Retina 10-11 pt.
        case smallText
        case punctuationAndDigits
        case code
        case multilineParagraph
    }

    public struct Sample: Sendable {
        public let id: String
        public let language: Language
        public let category: Category
        public let theme: Theme
        public let pointSize: Double
        public let scale: Int
        public let lines: [String]
        /// Typographic rectangle of each line in image pixels, top-left origin.
        public let lineRects: [CGRect]
        public let image: CGImage

        public var isCleanTypedText: Bool { category == .prose }
        public var text: String { lines.joined(separator: "\n") }
    }

    public enum RenderError: Error, Sendable {
        case contextUnavailable
        case fontUnavailable
    }

    /// The full corpus: 104 samples, 52 per language.
    public static func samples() throws -> [Sample] {
        var result: [Sample] = []
        let sizes: [Double] = [13, 15, 17, 20]
        for language in Language.allCases {
            let prose = language == .english ? englishProse : portugueseProse
            let tag = language == .english ? "en" : "pt"
            for i in 0..<24 {
                result.append(
                    try render(
                        id: "\(tag)-prose-\(i)", language: language, category: .prose,
                        theme: i % 2 == 0 ? .light : .dark, pointSize: sizes[i % sizes.count], scale: 2,
                        lines: [prose[i], prose[(i + 7) % prose.count]]))
            }
            for i in 0..<8 {
                result.append(
                    try render(
                        id: "\(tag)-small-\(i)", language: language, category: .smallText,
                        theme: i % 2 == 0 ? .dark : .light, pointSize: i % 2 == 0 ? 11 : 10, scale: 1,
                        lines: [prose[(i * 3) % prose.count]]))
            }
            let punctuation = language == .english ? englishPunctuation : portuguesePunctuation
            for i in 0..<8 {
                result.append(
                    try render(
                        id: "\(tag)-punct-\(i)", language: language, category: .punctuationAndDigits,
                        theme: i % 2 == 0 ? .light : .dark, pointSize: [13.0, 14, 16][i % 3], scale: 2,
                        lines: [punctuation[i]]))
            }
            let code = language == .english ? englishCode : portugueseCode
            for i in 0..<8 {
                result.append(
                    try render(
                        id: "\(tag)-code-\(i)", language: language, category: .code,
                        theme: i % 2 == 0 ? .dark : .light, pointSize: [12.0, 13, 14][i % 3], scale: 2,
                        lines: [code[i], code[(i + 3) % code.count]]))
            }
            for i in 0..<4 {
                let start = i * 5
                result.append(
                    try render(
                        id: "\(tag)-para-\(i)", language: language, category: .multilineParagraph,
                        theme: i % 2 == 0 ? .light : .dark, pointSize: 12, scale: 2,
                        lines: (0..<4).map { prose[(start + $0 * 2 + 1) % prose.count] }))
            }
        }
        return result
    }

    /// A text-free image (solid theme background plus a faint rule) for the empty-result case.
    public static func blankImage(width: Int = 800, height: Int = 200, theme: Theme = .light) throws -> CGImage {
        let context = try makeContext(width: width, height: height, theme: theme)
        context.setFillColor(theme == .light ? CGColor(gray: 0.85, alpha: 1) : CGColor(gray: 0.25, alpha: 1))
        context.fill(CGRect(x: 40, y: height / 2, width: width - 80, height: 2))
        guard let image = context.makeImage() else { throw RenderError.contextUnavailable }
        return image
    }

    /// Renders arbitrary lines with the same pipeline (used for large cancellation inputs).
    public static func render(
        id: String, language: Language, category: Category, theme: Theme, pointSize: Double, scale: Int,
        lines: [String]
    ) throws -> Sample {
        let pixelSize = CGFloat(pointSize) * CGFloat(scale)
        let fontType: CTFontUIFontType = category == .code ? .userFixedPitch : .system
        guard let font = CTFontCreateUIFontForLanguage(fontType, pixelSize, nil) else {
            throw RenderError.fontUnavailable
        }
        let foreground = theme == .light ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 0.92, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground,
        ]
        let ctLines = lines.map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes))
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        var widths: [CGFloat] = []
        for line in ctLines {
            widths.append(CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading)))
        }
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        let lineHeight = ((ascent + descent + CTFontGetLeading(font)) * 1.3).rounded(.up)
        let margin = (pixelSize * 1.5).rounded()
        let width = Int((widths.max() ?? 0) + margin * 2)
        let height = Int(margin * 2 + lineHeight * CGFloat(lines.count))
        let context = try makeContext(width: width, height: height, theme: theme)
        var rects: [CGRect] = []
        for (index, line) in ctLines.enumerated() {
            let top = margin + lineHeight * CGFloat(index)
            let baselineFromTop = top + ascent
            context.textPosition = CGPoint(x: margin, y: CGFloat(height) - baselineFromTop)
            CTLineDraw(line, context)
            rects.append(CGRect(x: margin, y: top, width: widths[index], height: ascent + descent))
        }
        guard let image = context.makeImage() else { throw RenderError.contextUnavailable }
        return Sample(
            id: id, language: language, category: category, theme: theme, pointSize: pointSize, scale: scale,
            lines: lines, lineRects: rects, image: image)
    }

    private static func makeContext(width: Int, height: Int, theme: Theme) throws -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RenderError.contextUnavailable }
        context.setFillColor(theme == .light ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldSmoothFonts(false)
        return context
    }

    // MARK: - Content

    public static let englishProse = [
        "The quick brown fox jumps over the lazy dog.",
        "Please review the attached report before Friday.",
        "Our meeting has been moved to the third floor.",
        "Remember to back up your files every evening.",
        "The new version fixes several important bugs.",
        "Shipping is free for orders over 50 dollars.",
        "Click Save to keep your changes, or Cancel to discard them.",
        "Your password must contain at least 12 characters.",
        "The library opens at 9 and closes at 6 on weekdays.",
        "We received 248 responses to the customer survey.",
        "Set the oven to 180 degrees and bake for 25 minutes.",
        "The train to Boston leaves from platform 4.",
        "Temperatures will drop sharply after sunset tonight.",
        "Download the latest update from the settings panel.",
        "This document was last edited on March 14, 2025.",
        "Invoice 4471 is due within thirty days.",
        "Screenshots are stored only on this computer.",
        "Choose a folder where exported images will be saved.",
        "The garden needs water twice a week in summer.",
        "Annual revenue grew by 12 percent last year.",
        "Keep the window open while the paint dries.",
        "All participants must register before noon.",
        "Press the space bar to pause the video.",
        "The museum is closed on Mondays and public holidays.",
    ]

    public static let portugueseProse = [
        "A reunião foi adiada para a próxima terça-feira.",
        "Não se esqueça de salvar o arquivo antes de sair.",
        "O relatório anual está disponível na intranet.",
        "Você recebeu uma nova mensagem do suporte técnico.",
        "A previsão indica chuva forte à tarde em São Paulo.",
        "Clique em Exportar para gerar a imagem final.",
        "O pão de queijo acabou de sair do forno.",
        "As inscrições terminam no próximo sábado.",
        "Esta versão corrige vários erros de sincronização.",
        "O voo para Brasília sai às 14h30 do portão 7.",
        "A conta de luz vence no dia 15 de cada mês.",
        "Recebemos 312 respostas na pesquisa de satisfação.",
        "A coleção de outono chega às lojas em março.",
        "Configure a pasta onde as capturas serão salvas.",
        "O preço final inclui frete e impostos.",
        "Atenção: o elevador está em manutenção.",
        "A biblioteca funciona de segunda a sexta.",
        "Informe o código enviado para o seu celular.",
        "O coração da cidade fica perto da estação.",
        "Ações de educação ambiental começam em junho.",
        "O ônibus para o aeroporto sai às sete horas.",
        "Guarde o recibo para eventuais trocas.",
        "É proibido estacionar em frente à garagem.",
        "Maçãs, limões e açúcar estão na lista de compras.",
    ]

    public static let englishPunctuation = [
        "Total: $1,249.99 (tax included) — paid 03/15/2025.",
        "Call +1 (415) 555-0132, ext. 204; fax: 555-0199.",
        "Error #404: “Page not found” at /docs/v2/index.html",
        "Q3 results: +8.5% vs. Q2; margin 23.1%.",
        "Order ID: A7-9921-XK … shipped via UPS.",
        "Rates: 5% [min], 12% [max] & 7.25% {avg}.",
        "Meeting @ 10:45 AM — Room 3B, Bldg. #2.",
        "Version 2.14.3 (build 8812) — released 2025-06-01.",
    ]

    public static let portuguesePunctuation = [
        "Total: R$ 1.249,99 (impostos inclusos) — pago em 15/03/2025.",
        "Ligue (11) 98765-4321, ramal 204; e-mail: contato@exemplo.com.br",
        "Nº do pedido: 58.213 — entrega prevista às 18h.",
        "Juros de 2,5% a.m. (30 dias) + multa de 10%.",
        "Endereço: Av. Paulista, 1.578 — 3º andar, São Paulo/SP.",
        "CPF: 123.456.789-09; CEP: 01310-200.",
        "Promoção: “leve 3, pague 2” até 31/12!",
        "Versão 2.14.3 (compilação 8812) — lançada em 01/06/2025.",
    ]

    public static let englishCode = [
        "let total = items.reduce(0) { $0 + $1.price }",
        "if (count > 10) { return false; }",
        "for i in 0..<5 { print(\"value: \\(i)\") }",
        "const url = `https://example.com/api?id=${id}`;",
        "def area(r): return 3.14159 * r ** 2",
        "SELECT name, email FROM users WHERE id = 42;",
        "git commit -m \"fix: handle empty input\"",
        "x = [a * 2 for a in range(10) if a % 3 == 0]",
    ]

    public static let portugueseCode = [
        "let preço = calcularTotal(itens: carrinho)",
        "// TODO: validar o endereço de cobrança",
        "print(\"Olá, mundo! Ação concluída.\")",
        "if saldo < 0 { alerta(\"Saldo insuficiente\") }",
        "var mensagem = \"Configuração salva com sucesso\"",
        "SELECT nome, cidade FROM clientes WHERE uf = 'SP';",
        "# Função que calcula a média das notas",
        "retorno = {\"status\": \"ok\", \"código\": 200}",
    ]
}
