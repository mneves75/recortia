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

            try await plantedChrome(context)
            try await checkerboardStaysOnScreen(harness, context)
        }

        /// The chrome control's planted case: a surface that paints a fixed white background must fail
        /// the dark check on the near-white fill, and one that paints fixed black must fail the
        /// light check, or the control cannot see the defect it exists for.
        static func plantedChrome(_ context: ScenarioContext) async throws {
            let plants: [(String, Color, NSAppearance.Name, (ChromeAppearance.Measure) -> Bool)] = [
                ("a fixed white surface rendered dark", .white, .darkAqua, { $0.fill > ChromeAppearance.fillCeiling }),
                ("a fixed black surface rendered light", .black, .aqua, { $0.median < ChromeAppearance.lightFloor }),
            ]
            for (name, color, appearance, intended) in plants {
                let surface = VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "Planted chrome").font(.headline)
                    Text(verbatim: "Fixed background, any appearance").foregroundStyle(.secondary)
                    Toggle(isOn: .constant(true)) { Text(verbatim: "Control") }
                }
                .padding(20)
                .frame(width: 360, height: 220, alignment: .topLeading)
                .background(color)
                let window = E2ESnapshot.host(surface, appearance: appearance)
                defer { window.close() }
                let root = try context.unwrap("planted host for \(name)", window.contentView)
                await E2ESnapshot.settle(root)
                let measure = try context.chromeMeasure(root, excluding: [])
                let failures = ChromeAppearance.failures(measure, dark: appearance == .darkAqua)
                context.check(
                    "planted: \(name) fails the chrome check on the intended measure",
                    !failures.isEmpty && intended(measure),
                    ([measure.description] + failures).joined(separator: "; "))
            }
        }

        /// The editor's transparency checkerboard follows the appearance on screen and never reaches
        /// an export, a pin, or the color picker: they read document pixels, not the canvas view.
        static func checkerboardStaysOnScreen(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let image = try E2EDrawing.image(size: CGSize(width: 200, height: 120), scale: 1) { rect in
                NSColor(srgbRed: 0.95, green: 0.45, blue: 0.1, alpha: 1).setFill()
                CGRect(x: rect.midX, y: 0, width: rect.width / 2, height: rect.height).fill()
            }
            let controller = try await harness.openImported(image, name: "half-transparent.png")
            defer { controller.window?.close() }
            let model = controller.model
            let window = try context.unwrap("the editor has a window", controller.window)
            let transparent = Rect<DocumentSpace>(x: 10, y: 10, width: 80, height: 100)
            var exports: [NSAppearance.Name: Data] = [:]
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let name = appearance == .darkAqua ? "dark" : "light"
                E2ESnapshot.park(window, appearance: appearance)
                await E2EActions.snapshotEditor(controller, context, shot: "checkerboard-\(name)")
                let canvas = try context.unwrap("\(name): the canvas view", controller.canvasView)
                let png = try E2ESnapshot.png(of: canvas, background: nil)
                let pixels = try ContainerInspector.decodePixels(png)
                var area = model.viewport.viewRect(transparent).cg
                if !canvas.isFlipped { area.origin.y = canvas.bounds.height - area.maxY }
                let luminance = ChromeAppearance.meanLuminance(pixels, in: area, scale: E2ESnapshot.scale)
                let expected = appearance == .darkAqua ? luminance <= ChromeAppearance.darkCeiling : luminance >= 0.6
                context.check(
                    "\(name): the on-screen checkerboard follows the appearance", expected,
                    String(format: "mean relative luminance %.3f over the transparent area", luminance))

                let copied = await E2EActions.export(controller, .copy)
                try context.require("\(name): Copy succeeds", copied == .copied, "\(copied)")
                let data = try context.unwrap(
                    "\(name): PNG on the pasteboard", harness.clipboard.pasteboard.data(forType: .png))
                exports[appearance] = data
                let exported = try E2EActions.decode(data, "\(name) export", context)
                context.check(
                    "\(name): exported transparent pixels stay transparent", exported.pixel(x: 20, y: 60).a == 0,
                    exported.pixel(x: 20, y: 60).hex)

                await model.pin()
                let pin = try context.unwrap("\(name): a pin", harness.features.pins.pins.last)
                let pinned = try E2EActions.pixels(of: pin.image, "\(name) pin", context)
                context.check(
                    "\(name): the pin's transparent pixels stay transparent", pinned.pixel(x: 20, y: 60).a == 0,
                    pinned.pixel(x: 20, y: 60).hex)
                harness.features.pins.close(pin.id)

                // A different neighborhood clears the earlier pick, so each appearance samples anew.
                model.setColorSampleSize(appearance == .darkAqua ? .threeByThree : .singlePixel)
                E2EActions.click(model, .colorPicker, at: E2EActions.point(20, 60))
                let picked = await E2EWait.until { model.pickedColor != nil }
                context.check(
                    "\(name): the color picker samples the document, not the checkerboard",
                    picked && model.pickedColor?.color.a == 0, "\(String(describing: model.pickedColor))")
                model.selectTool(.select)
            }
            context.check(
                "the export is byte-identical in light and dark appearance",
                exports[.aqua] != nil && exports[.aqua] == exports[.darkAqua])
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

    /// Chrome appearance control (editor redesign, Slice 4). App chrome must be dark in dark
    /// appearance and light in light appearance, and a dark surface must not carry a fixed light
    /// fill. Measured on the chrome of a surface only: user content (the editor canvas, a pin's
    /// image, the drag chip's thumbnail) is masked out by its view's frame. Surfaces drawn over user
    /// content by design (region overlay, handles, seam markers) are judged by the two-tone rule in
    /// `AppearanceScenarios`, not here.
    ///
    /// Two renderings of the same view feed it: the composite as shown (over the window ground,
    /// as `ScenarioContext.snapshot` saves it) gives the median luminance; the view over opaque
    /// black gives the fill, because a near-white pixel over black can only come from the surface.
    @MainActor
    enum ChromeAppearance {
        /// Dark chrome: median relative luminance at or below this (sRGB #595959 is 0.10).
        static let darkCeiling = 0.10
        /// Light chrome: median relative luminance at or above this (sRGB #CBCBCB is 0.60).
        static let lightFloor = 0.60
        /// A near-white pixel (sRGB #E7E7E7 and up).
        static let nearWhite = 0.80
        /// A near-white horizontal run at least this long (points) is a fill, not a glyph stroke.
        static let fillRunPoints = 12
        /// In dark appearance, at most this share of the chrome may lie in near-white fills.
        static let fillCeiling = 0.03

        struct Measure: CustomStringConvertible {
            let median: Double
            let fill: Double
            let samples: Int

            var description: String {
                String(
                    format: "median luminance %.3f, near-white fill %.1f%% of %d samples", median, fill * 100,
                    samples)
            }
        }

        /// The reasons `measure` fails its appearance; empty when it passes.
        static func failures(_ measure: Measure, dark: Bool) -> [String] {
            var reasons: [String] = []
            if measure.samples == 0 { reasons.append("no chrome was sampled") }
            if dark {
                if measure.median > darkCeiling {
                    reasons.append(
                        String(format: "median %.3f above the dark ceiling %.2f", measure.median, darkCeiling))
                }
                if measure.fill > fillCeiling {
                    reasons.append(
                        String(format: "near-white fill %.1f%% above %.0f%%", measure.fill * 100, fillCeiling * 100))
                }
            } else if measure.median < lightFloor {
                reasons.append(String(format: "median %.3f below the light floor %.2f", measure.median, lightFloor))
            }
            return reasons
        }

        /// Samples one pixel per point (the renders are 2×). `chrome` answers in pixel coordinates,
        /// row 0 on top.
        static func measure(composite: DecodedPixels, overBlack: DecodedPixels, chrome: (Int, Int) -> Bool) -> Measure {
            guard composite.width == overBlack.width, composite.height == overBlack.height else {
                return Measure(median: 0, fill: 0, samples: 0)
            }
            let step = Int(E2ESnapshot.scale)
            var histogram = [Int](repeating: 0, count: 1001)
            var samples = 0, filled = 0
            for y in stride(from: 0, to: composite.height, by: step) {
                var run = 0
                func endRun() {
                    if run >= fillRunPoints { filled += run }
                    run = 0
                }
                for x in stride(from: 0, to: composite.width, by: step) {
                    guard chrome(x, y) else {
                        endRun()
                        continue
                    }
                    let index = (y * composite.width + x) * 4
                    samples += 1
                    histogram[Int((luminance(composite.bytes, index) * 1000).rounded())] += 1
                    if luminance(overBlack.bytes, index) >= nearWhite { run += 1 } else { endRun() }
                }
                endRun()
            }
            var median = 0.0, seen = 0
            for (bin, count) in histogram.enumerated() {
                seen += count
                if seen * 2 >= samples {
                    median = Double(bin) / 1000
                    break
                }
            }
            return Measure(median: median, fill: samples == 0 ? 0 : Double(filled) / Double(samples), samples: samples)
        }

        /// Mean relative luminance of `rect` (points, top-left origin).
        static func meanLuminance(_ pixels: DecodedPixels, in rect: CGRect, scale: CGFloat) -> Double {
            let minX = max(0, Int(rect.minX * scale)), maxX = min(pixels.width, Int(rect.maxX * scale))
            let minY = max(0, Int(rect.minY * scale)), maxY = min(pixels.height, Int(rect.maxY * scale))
            var total = 0.0, count = 0
            for y in minY..<max(minY, maxY) {
                for x in minX..<max(minX, maxX) {
                    total += luminance(pixels.bytes, (y * pixels.width + x) * 4)
                    count += 1
                }
            }
            return count == 0 ? .nan : total / Double(count)
        }

        private static let linear: [Double] = (0...255).map { value in
            let channel = Double(value) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }

        private static func luminance(_ bytes: [UInt8], _ index: Int) -> Double {
            0.2126 * linear[Int(bytes[index])] + 0.7152 * linear[Int(bytes[index + 1])]
                + 0.0722 * linear[Int(bytes[index + 2])]
        }
    }

    extension ScenarioContext {
        /// Measures `view`'s chrome as it renders now, masking out `excluding` (user content).
        /// `areas` are further user-content rectangles in points, top-left origin.
        func chromeMeasure(_ view: NSView, excluding: [NSView], areas: [CGRect] = []) throws
            -> ChromeAppearance.Measure
        {
            let root = Self.rendered(view)
            let composite = try ContainerInspector.decodePixels(
                E2ESnapshot.png(of: root, background: .windowBackgroundColor))
            let overBlack = try ContainerInspector.decodePixels(E2ESnapshot.png(of: root, background: .black))
            let scale = E2ESnapshot.scale
            let viewAreas: [CGRect] = excluding.map { content in
                var rect = root.convert(content.bounds, from: content)
                if !root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
                return rect
            }
            let masks = (viewAreas + areas).map {
                CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale)
            }
            return ChromeAppearance.measure(composite: composite, overBlack: overBlack) { x, y in
                let point = CGPoint(x: x, y: y)
                return !masks.contains { $0.contains(point) }
            }
        }

        /// Records whether `view`'s chrome follows `appearance` (the chrome control above).
        func checkChrome(
            _ view: NSView, surface: String, appearance: NSAppearance.Name, excluding: [NSView] = [],
            areas: [CGRect] = []
        ) {
            let dark = appearance == .darkAqua
            let name = "\(surface): chrome follows \(dark ? "dark" : "light") appearance"
            do {
                let measure = try chromeMeasure(view, excluding: excluding, areas: areas)
                let failures = ChromeAppearance.failures(measure, dark: dark)
                check(name, failures.isEmpty, ([measure.description] + failures).joined(separator: "; "))
            } catch {
                check(name, false, "\(error)")
            }
        }

        /// After the light screenshot of `view`: checks its light chrome, switches `window` to dark,
        /// saves `<shot>-dark` and checks the dark chrome, then restores light so later light
        /// screenshots render exactly as before.
        func darkCompanion(
            _ view: NSView, in window: NSWindow, shot: String?, surface: String, excluding: [NSView] = [],
            settle: Duration = .milliseconds(250)
        ) async {
            checkChrome(view, surface: surface, appearance: .aqua, excluding: excluding)
            window.appearance = NSAppearance(named: .darkAqua)
            await E2ESnapshot.settle(view, for: settle)
            snapshot(view, shot: shot.map { "\($0)-dark" } ?? "dark")
            checkChrome(view, surface: surface, appearance: .darkAqua, excluding: excluding)
            window.appearance = NSAppearance(named: .aqua)
            await E2ESnapshot.settle(view, for: settle)
        }

        /// Like `darkCompanion` for content hosted by `E2ESnapshot.host`, whose color scheme is fixed
        /// when hosted: the dark rendering is a second host of the same content.
        func darkHosted<Content: View>(
            _ content: Content, light: NSView, size: NSSize? = nil, shot: String?, surface: String,
            areas: [CGRect] = [], settle: Duration = .milliseconds(250)
        ) async {
            checkChrome(light, surface: surface, appearance: .aqua, areas: areas)
            let window = E2ESnapshot.host(content, size: size, appearance: .darkAqua)
            defer { window.close() }
            guard let root = window.contentView else {
                check("\(surface): dark host has content", false)
                return
            }
            await E2ESnapshot.settle(root, for: settle)
            snapshot(root, shot: shot.map { "\($0)-dark" } ?? "dark")
            checkChrome(root, surface: surface, appearance: .darkAqua, areas: areas)
        }
    }
#endif
