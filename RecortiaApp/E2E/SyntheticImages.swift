#if DEBUG
    import AppKit
    import CoreGraphics
    import Domain
    import RecortiaFixtures

    /// A generated stand-in for a real desktop: numbered corner markers, two app-like windows, text
    /// in English and Portuguese, and a fake secret. Geometry is in desktop points (top-left origin);
    /// the image has `scale` pixels per point. Nothing here comes from the real screen.
    enum SyntheticDesktop {
        static let size = CGSize(width: 1280, height: 800)
        static let scale = 2.0
        static let markerSide = 64.0
        /// Corner markers in reading order: 1 top-left, 2 top-right, 3 bottom-left, 4 bottom-right.
        static let markerColors: [RGBA] = [
            RGBA(r: 214, g: 40, b: 40), RGBA(r: 40, g: 160, b: 60), RGBA(r: 40, g: 80, b: 210),
            RGBA(r: 230, g: 170, b: 0),
        ]
        static let notesWindow = CGRect(x: 200, y: 140, width: 640, height: 420)
        static let terminalWindow = CGRect(x: 760, y: 420, width: 440, height: 300)
        /// The fake secret line inside the notes window.
        static let secretRect = CGRect(x: 232, y: 452, width: 520, height: 44)
        static let secretText = "API key: sk-live-4111-1111-1111-1111"

        static var pixelSize: PixelSize {
            PixelSize(width: Int(size.width * scale), height: Int(size.height * scale))
        }

        static func markerRect(_ index: Int) -> CGRect {
            let x = index % 2 == 0 ? 0 : size.width - markerSide
            let y = index < 2 ? 0 : size.height - markerSide
            return CGRect(x: x, y: y, width: markerSide, height: markerSide)
        }

        static func image() throws -> CGImage {
            try E2EDrawing.image(size: size, scale: scale) { rect in
                let gradient = NSGradient(
                    starting: NSColor(srgbRed: 0.17, green: 0.24, blue: 0.45, alpha: 1),
                    ending: NSColor(srgbRed: 0.42, green: 0.30, blue: 0.58, alpha: 1))
                gradient?.draw(in: rect, angle: -90)
                NSColor(white: 0.93, alpha: 1).setFill()
                CGRect(x: 0, y: 0, width: size.width, height: 26).fill()
                E2EDrawing.text(
                    "Synthetic Desktop — Recortia E2E", at: CGPoint(x: 90, y: 5), size: 13, weight: .semibold)

                drawWindow(
                    notesWindow, title: "Notes — Quarterly report",
                    lines: [
                        "Quarterly report draft", "Revenue grew 12% in Q3; see figure 4.",
                        "Relatório trimestral: ação, coração, pão e maçã.", "Próxima reunião na sexta-feira às 14h.",
                    ])
                NSColor(srgbRed: 1, green: 0.96, blue: 0.75, alpha: 1).setFill()
                secretRect.fill()
                E2EDrawing.text(
                    secretText, at: CGPoint(x: secretRect.minX + 12, y: secretRect.minY + 11), size: 18,
                    weight: .medium, monospaced: true)
                drawWindow(
                    terminalWindow, title: "Terminal — build",
                    lines: ["$ swift build", "Build complete!", "$ ./run --demo", "ok: 42 checks passed"],
                    dark: true)

                for index in 0..<4 {
                    let marker = markerRect(index)
                    let color = markerColors[index]
                    NSColor(
                        srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255,
                        alpha: 1
                    ).setFill()
                    marker.fill()
                    E2EDrawing.text(
                        "\(index + 1)", at: CGPoint(x: marker.midX - 12, y: marker.midY - 22), size: 36, weight: .bold,
                        color: .white)
                }
            }
        }

        private static func drawWindow(_ frame: CGRect, title: String, lines: [String], dark: Bool = false) {
            NSColor(white: 0, alpha: 0.25).setFill()
            NSBezierPath(roundedRect: frame.offsetBy(dx: 0, dy: 6), xRadius: 12, yRadius: 12).fill()
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).fill()
            NSColor(white: dark ? 0.2 : 0.9, alpha: 1).setFill()
            CGRect(x: frame.minX, y: frame.minY + 12, width: frame.width, height: 22).fill()
            NSBezierPath(
                roundedRect: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 34), xRadius: 12,
                yRadius: 12
            ).fill()
            E2EDrawing.text(
                title, at: CGPoint(x: frame.minX + 80, y: frame.minY + 9), size: 13, weight: .semibold,
                color: dark ? .white : .black)
            for (index, dotColor) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                dotColor.setFill()
                NSBezierPath(
                    ovalIn: CGRect(x: frame.minX + 14 + CGFloat(index) * 20, y: frame.minY + 11, width: 12, height: 12)
                )
                .fill()
            }
            for (index, line) in lines.enumerated() {
                E2EDrawing.text(
                    line, at: CGPoint(x: frame.minX + 32, y: frame.minY + 60 + CGFloat(index) * 40), size: 20,
                    weight: index == 0 ? .bold : .regular, color: dark ? NSColor(white: 0.9, alpha: 1) : .black,
                    monospaced: dark)
            }
        }
    }

    /// Small top-left-origin drawing helpers for synthetic images.
    enum E2EDrawing {
        /// Draws into a new sRGB bitmap of `size` points at `scale` pixels per point, top-left origin.
        static func image(size: CGSize, scale: Double, _ draw: (CGRect) -> Void) throws -> CGImage {
            let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw E2EAbort("cannot create a \(width)×\(height) drawing context") }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            draw(CGRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            guard let image = context.makeImage() else { throw E2EAbort("drawing produced no image") }
            return image
        }

        static func text(
            _ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular,
            color: NSColor = .black, monospaced: Bool = false
        ) {
            let font =
                monospaced
                ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
        }

        /// Places `images` left to right on a white canvas with `margin` points between them.
        static func row(_ images: [CGImage], margin: Int) throws -> CGImage {
            let width = images.reduce(margin) { $0 + $1.width + margin }
            let height = (images.map(\.height).max() ?? 0) + margin * 2
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw E2EAbort("cannot create a \(width)×\(height) row context") }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .none
            var x = margin
            for image in images {
                context.draw(image, in: CGRect(x: x, y: margin, width: image.width, height: image.height))
                x += image.width + margin
            }
            guard let image = context.makeImage() else { throw E2EAbort("row composition produced no image") }
            return image
        }

        static func png(_ image: CGImage) throws -> Data {
            do {
                return try ContainerCrafting.pngData(image)
            } catch {
                throw E2EAbort("PNG encoding of a fixture failed: \(error)")
            }
        }

        static func jpeg(_ image: CGImage) throws -> Data {
            do {
                return try ContainerCrafting.jpegData(image)
            } catch {
                throw E2EAbort("JPEG encoding of a fixture failed: \(error)")
            }
        }
    }
#endif
