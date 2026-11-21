#if DEBUG
    import AppKit
    import Domain
    import Features
    import RecortiaFixtures

    /// The colour picker's copy formats, darkest-pixel sampling and WCAG contrast in a real editor
    /// (FR-11, A-7). Copies land on the runner's private text pasteboard, never the general one.
    @MainActor
    enum ColourToolsScenarios {
        static let grey = RGBA(r: 0x77, g: 0x77, b: 0x77)
        static let ink = RGBA(r: 0x10, g: 0x20, b: 0x30)
        static let maskFill = RGBA(r: 0xC8, g: 0xC8, b: 0xC8)

        /// 384 × 192: #777777 on the left half, white on the right, a 4-pixel #102030 "glyph" at
        /// (284, 44) and a black "secret" at (300, 140), 10 pixels square.
        static func fixture() throws -> CGImage {
            let width = 384, height = 192
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            func paint(_ x: Range<Int>, _ y: Range<Int>, _ color: RGBA) {
                for row in y {
                    for column in x {
                        let i = (row * width + column) * 4
                        bytes.replaceSubrange(i..<i + 3, with: [color.r, color.g, color.b])
                    }
                }
            }
            paint(0..<192, 0..<height, grey)
            paint(284..<288, 44..<48, ink)
            paint(300..<310, 140..<150, .black)
            return try ChartFixture.image(width: width, height: height, premultipliedRGBA: bytes)
        }

        static func colourTools(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let preferences = harness.settings.preferences
            defer { harness.settings.update { $0.colorFormatChoice = preferences.colorFormatChoice } }
            harness.settings.update { $0.colorFormatChoice = nil }
            let image: CGImage
            do { image = try fixture() } catch { throw E2EAbort("colour fixture: \(error)") }
            let controller = try await harness.openImported(image, name: "colour-tools.png")
            let model = controller.model
            let root = try context.unwrap("editor content", controller.contentRoot)
            let window = try context.unwrap("editor window", controller.window)
            try await E2EAccessibilityControl.showAndActivate(window, context)
            let p = E2EActions.point
            let snapshots = harness.exportGate.snapshotCount
            let imageClipboard = harness.clipboard.pasteboard.changeCount
            func pick(_ point: Point<DocumentSpace>) async throws -> RGBA {
                E2EActions.click(model, .colorPicker, at: point)
                try context.require("the pick completes", await E2EWait.until { model.pickedColor != nil })
                return try context.unwrap("a picked colour", model.pickedColor?.color)
            }
            func copied() -> String? { harness.textPasteboard.string(forType: .string) }
            func show() async {
                await E2ESnapshot.settle(root)
                await E2EActions.scrollInspector(controller, to: 1)
                await E2ESnapshot.settle(root)
            }

            // The format preference changes the copied string.
            try context.require("the sanitized preview is current", await E2EWait.until { model.isBaseCurrent })
            context.check("the copy format starts as HEX", model.colorFormat == .hex, "\(model.colorFormat)")
            let beforePick = harness.textPasteboard.changeCount
            context.check("picking #777777", try await pick(p(96, 96)) == grey)
            context.check("picking alone copies nothing", harness.textPasteboard.changeCount == beforePick)
            await show()
            try E2EAccessibilityControl.click("color.copy", in: root, context)
            context.check(
                "the native Copy writes HEX",
                await E2EWait.until { harness.textPasteboard.changeCount != beforePick && copied() == "#777777" },
                String(describing: copied()))
            let expected: [(ColorFormat, String)] = [
                (.cssRGB, "rgb(119, 119, 119)"),
                (.normalizedRGB, "0.467, 0.467, 0.467"),
                (.swiftUI, "Color(red: 0.467, green: 0.467, blue: 0.467)"),
                (.uiKit, "UIColor(red: 0.467, green: 0.467, blue: 0.467, alpha: 1)"),
                (.android, "0xFF777777"),
                (.oklch, "oklch(56.93% 0 0)"),
            ]
            for (format, string) in expected {
                model.colorFormat = format
                context.check("\(format) is remembered", harness.settings.preferences.colorFormat == format)
                context.check("Copy as \(format)", model.copyPickedColor())
                context.check(
                    "\(format) text on the private pasteboard", copied() == string, String(describing: copied()))
            }
            await show()
            context.check(
                "the picker shows the text it copies",
                try E2EAccessibilityControl.text(.value, for: "color.formatted", in: root, context) == expected.last?.1)
            await E2EActions.snapshotEditor(controller, context, shot: "colour-formats")
            model.colorFormat = .hex

            // Contrast of the synthetic two-colour fixture: #777777 on white is 4.478:1.
            let beforeContrast = harness.textPasteboard.changeCount
            await show()
            try E2EAccessibilityControl.click("color.useAsText", in: root, context)
            try context.require("the grey becomes the text colour", await E2EWait.until { model.contrastText == grey })
            context.check("picking white", try await pick(p(250, 96)) == .white)
            await show()
            try E2EAccessibilityControl.click("color.useAsBackground", in: root, context)
            try context.require("the white becomes the background", await E2EWait.until { model.contrast != nil })
            let contrast = try context.unwrap("a contrast ratio", model.contrast)
            context.check("the ratio is 4.478", abs(contrast.ratio - 4.4781) < 0.0001, "\(contrast.ratio)")
            await show()
            let ratioText = contrast.shownRatio.formatted(.number.precision(.fractionLength(2))) + ":1"
            context.check("the readout shows 4.47:1, truncated", ["4.47:1", "4,47:1"].contains(ratioText), ratioText)
            context.check(
                "the readout is on screen",
                try E2EAccessibilityControl.text(.value, for: "color.contrast.ratio", in: root, context) == ratioText)
            let pass = String(localized: "Pass", table: "Editor"), fail = String(localized: "Fail", table: "Editor")
            for (id, mark) in [("aa.normal", fail), ("aa.large", pass), ("aaa.normal", fail), ("aaa.large", fail)] {
                context.check(
                    "\(id) reads \(mark)",
                    try E2EAccessibilityControl.text(.value, for: "color.contrast.\(id)", in: root, context) == mark)
            }
            await E2EActions.snapshotEditor(controller, context, shot: "colour-contrast")
            if let window = controller.window {
                let appearance = window.appearance
                window.appearance = NSAppearance(named: .darkAqua)
                await show()
                await E2EActions.snapshotEditor(controller, context, shot: "colour-contrast-dark")
                window.appearance = appearance
            }
            context.check("contrast copies nothing", harness.textPasteboard.changeCount == beforeContrast)

            // Darkest sampling picks the glyph out of a white box.
            context.check("a point pick beside the glyph is white", try await pick(p(280, 40)) == .white)
            model.samplesDarkestPixel = true
            context.check("darkest sampling finds the glyph colour", try await pick(p(280, 40)) == ink)
            context.check("Copy of the darkest pick", model.copyPickedColor() && copied() == "#102030")
            context.check(
                "control: darkest sampling finds the secret before it is masked", try await pick(p(305, 145)) == .black)

            // Sampling over a secure mask reads the mask's fill, never what it hides.
            model.setRedactionFill(maskFill)
            E2EActions.drag(model, .redact, from: p(290, 130), to: p(330, 170))
            context.check("one secure mask", model.document.masks.count == 1)
            context.check(
                "a redaction clears the contrast pair", model.contrastText == nil && model.contrastBackground == nil)
            try context.require("the sanitized preview refreshes", await E2EWait.until { model.isBaseCurrent })
            context.check("darkest sampling over the mask reads its fill", try await pick(p(305, 145)) == maskFill)
            model.samplesDarkestPixel = false
            context.check("a point pick over the mask reads its fill", try await pick(p(305, 145)) == maskFill)
            await E2EActions.snapshotEditor(controller, context, shot: "colour-mask")

            context.check(
                "copies used the private text pasteboard", harness.textPasteboard.name != .general,
                harness.textPasteboard.name.rawValue)
            context.check("colour tools create no export snapshot", harness.exportGate.snapshotCount == snapshots)
            context.check(
                "colour tools leave the image clipboard unchanged",
                harness.clipboard.pasteboard.changeCount == imageClipboard)
        }
    }
#endif
