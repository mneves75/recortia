#if DEBUG
    import AppKit
    import Domain
    import Features
    import MacPlatform
    import RecortiaFixtures
    import SwiftUI

    /// Rendered-output control for appearance.
    ///
    /// Every other scenario snapshots in light appearance against light app chrome, so a defect
    /// that only exists where chrome meets page content had no instrument at all. This one renders
    /// the scrolling review twice — once with seams and once without — and measures the pixels that
    /// changed. The difference is exactly the seam markers, so the assertion is about the marks the
    /// review asks the user to check, not about the code that draws them.
    @MainActor
    enum AppearanceScenarios {
        /// WCAG relative-luminance contrast floor for a non-text mark.
        private static let minimumContrast = 3.0
        /// A marker that does not cross the preview is not the seam mark the review promises.
        private static let minimumSpan = 0.8

        static func reviewContrast(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            // A landscape page keeps both seams inside the review's 360 pt preview viewport: a
            // tall page is scaled to the preview width and the lower seam is clipped away.
            let width = 480, height = 300
            let seams = [80, 240]
            let pages: [(String, NSColor)] = [
                ("a dark page", NSColor(white: 0.06, alpha: 1)),
                ("a light page", NSColor(white: 0.97, alpha: 1)),
                // Mid grey is the worst case for a keyline: neither stroke is far from the content.
                ("a mid grey page", NSColor(white: 0.5, alpha: 1)),
            ]
            for (pageName, pageColor) in pages {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let name = appearance == .darkAqua ? "dark appearance" : "light appearance"
                    let clean = try await render(
                        width: width, height: height, pageColor: pageColor, seams: [], appearance: appearance)
                    let marked = try await render(
                        width: width, height: height, pageColor: pageColor, seams: seams, appearance: appearance)
                    let measured = measure(clean: clean, marked: marked)
                    context.check(
                        "every seam marker keeps contrast on \(pageName) in \(name)",
                        measured.weakestBand >= minimumContrast,
                        String(
                            format: "weakest band %.2f:1 over %d changed pixels", measured.weakestBand,
                            measured.changed))
                    // The marks must be where the seams are, spanning the width, not a blob
                    // somewhere else in the preview that happens to be visible.
                    context.check(
                        "one marker band per seam spans the preview on \(pageName) in \(name)",
                        measured.bands == seams.count && measured.narrowestSpan >= minimumSpan,
                        String(
                            format: "%d bands, narrowest %.0f%% of the width",
                            measured.bands, measured.narrowestSpan * 100))
                }
            }

            // The review exists to be dismissed: a titled window keeps its close button, only the
            // controller is its delegate, and the one destructive exit asks first.
            let controller = ScrollUIController(model: harness.features.scroll, displays: { [] })
            let window = controller.makeReviewWindow()
            defer { window.close() }
            context.check(
                "the review window can be closed",
                window.styleMask.contains(.closable) && window.standardWindowButton(.closeButton) != nil,
                "styleMask=\(window.styleMask.rawValue)")
            context.check(
                "the controller is the window's delegate, so close is answered",
                window.delegate === controller, "\(String(describing: window.delegate))")
            var asked = 0
            controller.confirmDiscard = {
                asked += 1
                return false
            }
            context.check(
                "closing the review asks before discarding", controller.windowShouldClose(window) == false,
                "asked=\(asked)")
            context.check("the question is asked exactly once per attempt", asked == 1, "asked=\(asked)")
            controller.confirmDiscard = {
                asked += 1
                return true
            }
            context.check(
                "a confirmed discard closes the review", controller.windowShouldClose(window) == true,
                "asked=\(asked)")
        }

        private static func render(
            width: Int, height: Int, pageColor: NSColor, seams: [Int], appearance: NSAppearance.Name
        ) async throws -> DecodedPixels {
            let preview = try E2EDrawing.image(
                size: CGSize(width: width, height: height), scale: 1
            ) { rect in
                pageColor.setFill()
                rect.fill()
            }
            let view = ScrollReviewView(
                preview: preview, outputSize: PixelSize(width: width, height: height), seams: seams,
                partialReason: nil, assemblyFailed: false, onAccept: {}, onDiscard: {})
            let window = E2ESnapshot.host(view, appearance: appearance)
            defer { window.close() }
            guard let root = window.contentView else { throw E2EAbort("the review host has no content") }
            await E2ESnapshot.settle(root)
            let png = try E2ESnapshot.png(of: root, background: nil)
            guard let representation = NSBitmapImageRep(data: png), let image = representation.cgImage
            else { throw E2EAbort("the review snapshot did not decode") }
            return try ContainerInspector.pixels(of: image)
        }

        /// Where the marks are and how they read: the strongest contrast of any changed pixel
        /// against the content it replaced, the number of horizontal bands that changed, and the
        /// narrowest horizontal span of a band as a share of the preview width. Counting bands is
        /// what separates "the seams are drawn across the image" from "something changed somewhere".
        private static func measure(clean: DecodedPixels, marked: DecodedPixels) -> (
            weakestBand: Double, bands: Int, narrowestSpan: Double, changed: Int
        ) {
            guard clean.width == marked.width, clean.height == marked.height else {
                return (0, 0, 0, 0)
            }
            var changed = 0
            var rows: [Int: (minX: Int, maxX: Int, strongest: Double)] = [:]
            for y in 0..<clean.height {
                for x in 0..<clean.width {
                    let index = (y * clean.width + x) * 4
                    let delta =
                        abs(Int(marked.bytes[index]) - Int(clean.bytes[index]))
                        + abs(Int(marked.bytes[index + 1]) - Int(clean.bytes[index + 1]))
                        + abs(Int(marked.bytes[index + 2]) - Int(clean.bytes[index + 2]))
                    guard delta > 6 else { continue }
                    changed += 1
                    let ratio = contrast(marked.bytes, clean.bytes, index)
                    let row = rows[y] ?? (minX: x, maxX: x, strongest: 0)
                    rows[y] = (min(row.minX, x), max(row.maxX, x), max(row.strongest, ratio))
                }
            }
            // A 1 pt dashed mark is a few rows tall; rows separated by a gap are another band.
            var bands: [(minX: Int, maxX: Int, lastRow: Int, strongest: Double)] = []
            for y in rows.keys.sorted() {
                guard let row = rows[y] else { continue }
                if let index = bands.indices.last, y - bands[index].lastRow <= 3 {
                    bands[index].minX = min(bands[index].minX, row.minX)
                    bands[index].maxX = max(bands[index].maxX, row.maxX)
                    bands[index].lastRow = y
                    bands[index].strongest = max(bands[index].strongest, row.strongest)
                } else {
                    bands.append((row.minX, row.maxX, y, row.strongest))
                }
            }
            let narrowest =
                bands.isEmpty
                ? 0 : bands.map { Double($0.maxX - $0.minX + 1) / Double(clean.width) }.min() ?? 0
            // The floor applies to every band, not to the brightest pixel anywhere: a mark that
            // reads well at one point and vanishes along the rest of the seam is not visible.
            let weakest = bands.map(\.strongest).min() ?? 0
            return (weakest, bands.count, narrowest, changed)
        }

        /// WCAG contrast ratio between one pixel and the pixel it replaced.
        private static func contrast(_ first: [UInt8], _ second: [UInt8], _ index: Int) -> Double {
            let one = luminance(first, index), two = luminance(second, index)
            return (max(one, two) + 0.05) / (min(one, two) + 0.05)
        }

        private static func luminance(_ bytes: [UInt8], _ index: Int) -> Double {
            func linear(_ value: UInt8) -> Double {
                let channel = Double(value) / 255
                return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(bytes[index]) + 0.7152 * linear(bytes[index + 1])
                + 0.0722 * linear(bytes[index + 2])
        }
    }
#endif
