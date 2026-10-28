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
        /// A marker that is only visible along a sliver of its length is not usable either.
        private static let minimumCovered = 0.15

        static func reviewContrast(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let width = 120, height = 300
            let seams = [80, 190]
            let pages: [(String, NSColor)] = [
                ("a dark page", NSColor(white: 0.06, alpha: 1)),
                ("a light page", NSColor(white: 0.97, alpha: 1)),
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
                        "seam markers keep contrast on \(pageName) in \(name)",
                        measured.strongest >= minimumContrast && measured.covered >= minimumCovered,
                        String(
                            format: "strongest %.2f:1, %.0f%% of marked pixels at or above %.0f:1, %d pixels changed",
                            measured.strongest, measured.covered * 100, minimumContrast, measured.changed))
                }
            }

            // The review exists to be dismissed: a titled window keeps its close button, and the
            // only destructive exit asks first.
            let model = harness.features.scroll
            let window = ScrollUIController.makeReviewWindow(model: model)
            defer { window.close() }
            context.check(
                "the review window can be closed",
                window.styleMask.contains(.closable) && window.standardWindowButton(.closeButton) != nil,
                "styleMask=\(window.styleMask.rawValue)")
            let controller = ScrollUIController(model: model, displays: { [] })
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

        /// The strongest contrast of any changed pixel against the content it replaced, and the
        /// share of changed pixels that reach the floor.
        private static func measure(clean: DecodedPixels, marked: DecodedPixels) -> (
            strongest: Double, covered: Double, changed: Int
        ) {
            guard clean.width == marked.width, clean.height == marked.height else {
                return (0, 0, 0)
            }
            var strongest = 0.0
            var changed = 0
            var covered = 0
            for index in stride(from: 0, to: clean.bytes.count, by: 4) {
                let delta =
                    abs(Int(marked.bytes[index]) - Int(clean.bytes[index]))
                    + abs(Int(marked.bytes[index + 1]) - Int(clean.bytes[index + 1]))
                    + abs(Int(marked.bytes[index + 2]) - Int(clean.bytes[index + 2]))
                guard delta > 6 else { continue }
                changed += 1
                let ratio = contrast(marked.bytes, clean.bytes, index)
                strongest = max(strongest, ratio)
                if ratio >= minimumContrast { covered += 1 }
            }
            return (strongest, changed == 0 ? 0 : Double(covered) / Double(changed), changed)
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
