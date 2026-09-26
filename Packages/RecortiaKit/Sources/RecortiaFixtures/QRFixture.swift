import CoreGraphics
import CoreImage
import Foundation

/// Synthetic QR codes (OCR-02) generated with Core Image, each with the exact message bytes it
/// encodes and the classification a conservative decoder must report.
public struct QRFixture: Sendable {
    /// Mirrors Imaging's `QRPayload.Kind` without importing Imaging.
    public enum ExpectedKind: Sendable, Equatable {
        case text
        case webURL(String)
        case otherScheme(String)
        case wifi
        case payment
        case binary
    }

    public let name: String
    /// Message bytes per code, in reading order (top-to-bottom, then left-to-right). Empty for
    /// malformed fixtures, which must yield no payload.
    public let expectedPayloads: [Data]
    public let expectedKinds: [ExpectedKind]
    public let image: CGImage

    public var isMalformed: Bool { expectedPayloads.isEmpty }

    public enum GenerationError: Error, Sendable {
        case generatorUnavailable
        case renderFailed
    }

    public static func all() throws -> [QRFixture] {
        let cases: [(String, Data, ExpectedKind)] = [
            ("plain-text", Data("Hello, Recortia! 123".utf8), .text),
            ("text-accents", Data("Olá, coração — pão às 13h".utf8), .text),
            ("numeric-only", Data("0123456789012345".utf8), .text),
            ("https", Data("https://example.com/path?q=1&r=two".utf8), .webURL("https://example.com/path?q=1&r=two")),
            ("http", Data("http://example.org/".utf8), .webURL("http://example.org/")),
            ("https-uppercase-alphanumeric-mode", Data("HTTPS://EXAMPLE.COM/A".utf8), .webURL("HTTPS://EXAMPLE.COM/A")),
            ("javascript-scheme", Data("javascript:alert(document.cookie)".utf8), .otherScheme("javascript")),
            ("file-scheme", Data("file:///etc/passwd".utf8), .otherScheme("file")),
            ("deep-link", Data("myapp://settings/reset?confirm=1".utf8), .otherScheme("myapp")),
            ("mailto", Data("mailto:someone@example.com".utf8), .otherScheme("mailto")),
            ("http-without-host", Data("http:relative/path".utf8), .otherScheme("http")),
            ("wifi", Data("WIFI:S:Recortia Lab;T:WPA;P:correct horse;;".utf8), .wifi),
            ("bitcoin", Data("bitcoin:bc1qexampleaddress0000000000000000?amount=0.01".utf8), .payment),
            (
                "pix-br-code",
                Data(pixPayload.utf8),
                .payment
            ),
            ("binary", Data([0xFF, 0xFE, 0x00, 0x80, 0x41, 0xC3]), .binary),
        ]
        var fixtures = try cases.map { name, data, kind in
            QRFixture(name: name, expectedPayloads: [data], expectedKinds: [kind], image: try image(of: [data]))
        }
        let first = Data("first code".utf8), second = Data("https://example.net/second".utf8)
        fixtures.append(
            QRFixture(
                name: "two-codes", expectedPayloads: [first, second],
                expectedKinds: [.text, .webURL("https://example.net/second")],
                image: try image(of: [first, second])))
        fixtures.append(
            QRFixture(
                name: "malformed-finders-erased", expectedPayloads: [], expectedKinds: [],
                image: try damaged(Data("damaged payload".utf8), eraseFinders: true, noiseFraction: 0)))
        fixtures.append(
            QRFixture(
                name: "malformed-heavy-noise", expectedPayloads: [], expectedKinds: [],
                image: try damaged(
                    Data("noisy payload that cannot be recovered".utf8), eraseFinders: false, noiseFraction: 0.5)))
        return fixtures
    }

    /// Module matrix for a message at error-correction level M (true = dark).
    static func modules(for message: Data, correctionLevel: String = "M") throws -> [[Bool]] {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw GenerationError.generatorUnavailable }
        filter.setValue(message, forKey: "inputMessage")
        filter.setValue(correctionLevel, forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
            let cg = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent),
            let gray = CGColorSpace(name: CGColorSpace.linearGray),
            let context = CGContext(
                data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width, space: gray,
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw GenerationError.renderFailed }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let rendered = context.makeImage(), let bytes = rendered.dataProvider?.data as Data? else {
            throw GenerationError.renderFailed
        }
        let stride = rendered.bytesPerRow
        // Core Image adds a 1-module quiet zone; bitmap memory rows are top-down.
        return (0..<cg.height).map { y in (0..<cg.width).map { x in bytes[y * stride + x] < 128 } }
    }

    /// Synthetic EMV/BR Code shape (fictitious key and CRC), not a payable code.
    static let pixPayload =
        "00020126360014BR.GOV.BCB.PIX0114+5511999999999520400005303986540510.00"
        + "5802BR5913FULANO DE TAL6008BRASILIA62070503***6304ABCD"

    private static let moduleSize = 8
    private static let quietModules = 4

    /// Codes laid out left to right on one white canvas.
    static func image(of messages: [Data]) throws -> CGImage {
        let matrices = try messages.map { try modules(for: $0) }
        return try draw(matrices)
    }

    private static func draw(_ matrices: [[[Bool]]]) throws -> CGImage {
        let sides = matrices.map(\.count)
        let width = sides.reduce(0) { $0 + ($1 + quietModules * 2) * moduleSize }
        let height = ((sides.max() ?? 0) + quietModules * 2) * moduleSize
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw GenerationError.renderFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        var originX = 0
        for matrix in matrices {
            for (row, cells) in matrix.enumerated() {
                for (column, dark) in cells.enumerated() where dark {
                    let x = originX + (column + quietModules) * moduleSize
                    let yFromTop = (row + quietModules) * moduleSize
                    context.fill(CGRect(x: x, y: height - yFromTop - moduleSize, width: moduleSize, height: moduleSize))
                }
            }
            originX += (matrix.count + quietModules * 2) * moduleSize
        }
        guard let image = context.makeImage() else { throw GenerationError.renderFailed }
        return image
    }

    /// A code damaged beyond its error correction: finder patterns erased and/or a seeded fraction
    /// of data modules flipped.
    private static func damaged(_ message: Data, eraseFinders: Bool, noiseFraction: Double) throws -> CGImage {
        var matrix = try modules(for: message)
        let side = matrix.count
        if eraseFinders {
            // Finder patterns occupy 7x7 modules inside the 1-module quiet zone at three corners.
            for (r0, c0) in [(1, 1), (1, side - 8), (side - 8, 1)] {
                for r in r0..<(r0 + 7) {
                    for c in c0..<(c0 + 7) { matrix[r][c] = false }
                }
            }
        }
        if noiseFraction > 0 {
            var state: UInt64 = 0x5EED_0F0F
            for r in 9..<(side - 9) {
                for c in 9..<(side - 9) {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    if Double(state >> 11) / Double(1 << 53) < noiseFraction { matrix[r][c].toggle() }
                }
            }
        }
        return try draw([matrix])
    }
}
