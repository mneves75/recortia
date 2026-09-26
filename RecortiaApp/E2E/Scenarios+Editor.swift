#if DEBUG
    import AppKit
    import Domain
    import Features
    import Imaging
    import RecortiaFixtures

    /// Editor tools through the real `EditorModel` gestures, rendered in real editor windows
    /// (FR-04, FR-05, FR-06, FR-11, FR-12, FR-13).
    @MainActor
    enum EditorScenarios {
        static let accentedText = "Revisão: ação, coração ✅ 👋🏽\nSegunda linha — café"

        static func annotations(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let controller = try await E2EActions.captureRegion(
                harness, CGRect(x: 180, y: 120, width: 700, height: 460), context)
            let model = controller.model
            let original = model.document
            let p = E2EActions.point

            // Text goes through the canvas's native text view, like typing.
            model.setFontSize(40)
            model.selectTool(.text)
            model.pointerDown(at: p(80, 60))
            model.pointerUp(at: p(80, 60))
            let canvas = try context.unwrap("canvas view", controller.canvasView)
            let appeared = await E2EWait.until {
                EditorWindowController.first(NSTextView.self, in: canvas) != nil
            }
            try context.require("the text tool opens a native text view", appeared)
            let textView = try context.unwrap("text view", EditorWindowController.first(NSTextView.self, in: canvas))
            textView.insertText(accentedText, replacementRange: textView.selectedRange())
            controller.commitPendingText()

            E2EActions.drag(model, .arrow, from: p(120, 300), to: p(420, 180))
            E2EActions.drag(model, .rectangle, from: p(480, 120), to: p(760, 300))
            E2EActions.drag(model, .ellipse, from: p(820, 140), to: p(1100, 320))
            let wave = (0...12).map { i in p(160 + Double(i) * 40, 520 + (i % 2 == 0 ? -30 : 30)) }
            E2EActions.drag(model, .freehand, from: p(160, 520), to: p(640, 520), via: wave)
            E2EActions.drag(model, .highlighter, from: p(700, 620), to: p(1200, 620))
            E2EActions.click(model, .step, at: p(1220, 120))
            E2EActions.click(model, .step, at: p(1220, 220))

            let kinds = model.listItems.reversed().map(\.kind).filter { $0 != .image }
            let expectedKinds: [EditorItemKind] = [
                .text, .arrow, .rectangle, .ellipse, .freehand, .highlighter, .step, .step,
            ]
            context.check("one annotation per tool, in order", kinds == expectedKinds, "\(kinds.map(\.rawValue))")
            if case .text(let text)? = model.document.annotations.first?.kind {
                context.check(
                    "text keeps accents, emoji, and the line break exactly", text.string == accentedText,
                    text.string.debugDescription)
            } else {
                context.check("the first annotation is text", false)
            }
            let steps = model.document.annotations.compactMap { annotation -> Int? in
                if case .step(_, let number) = annotation.kind { return number }
                return nil
            }
            context.check("numbered steps count 1, 2", steps == [1, 2], "\(steps)")
            context.check(
                "each gesture is one undo step", model.session.undoCount == 8, "undo steps: \(model.session.undoCount)")

            // Select the rectangle by clicking its stroke with the select tool.
            E2EActions.click(model, .select, at: p(480, 200))
            let rectangle = model.document.annotations[2]
            context.check(
                "clicking the stroke selects the rectangle", model.selection == [.annotation(rectangle.id)],
                "\(model.selection)")
            context.check(
                "a selected rectangle shows eight handles", model.selectionHandles.count == 8,
                "\(model.selectionHandles.count)")
            await E2EActions.snapshotEditor(controller, context, shot: "selection")

            let final = model.document
            var undos = 0
            while model.canUndo, undos < 100 {
                model.undo()
                undos += 1
            }
            context.check("undo-all returns to the captured image", model.document == original, "\(undos) undos")
            var redos = 0
            while model.canRedo, redos < 100 {
                model.redo()
                redos += 1
            }
            context.check("redo-all restores every annotation", model.document == final, "\(redos) redos")
            context.check("undo and redo counts match", undos == redos && undos == 8, "\(undos)/\(redos)")
        }

        static func redaction(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let notes = SyntheticDesktop.notesWindow
            let controller = try await E2EActions.captureRegion(harness, notes, context)
            let model = controller.model
            let p = E2EActions.point
            // Document pixels of the secret line: (desktop - capture origin) × 2.
            let secret = SyntheticDesktop.secretRect.offsetBy(dx: -notes.minX, dy: -notes.minY)
            let secretPixels = CGRect(
                x: secret.minX * 2, y: secret.minY * 2, width: secret.width * 2, height: secret.height * 2)
            let epoch = model.session.privacyEpoch
            E2EActions.drag(
                model, .redact, from: p(secretPixels.minX - 6, secretPixels.minY - 6),
                to: p(secretPixels.maxX + 6, secretPixels.maxY + 6))
            let mask = try context.unwrap("a secure mask was added", model.document.masks.first)
            context.check("the mask is opaque", mask.fill.a == 255, "\(mask.fill)")
            context.check("adding a mask advances the privacy epoch", model.session.privacyEpoch > epoch)
            E2EActions.drag(model, .blur, from: p(40, 100), to: p(700, 170))
            E2EActions.drag(model, .pixelate, from: p(40, 200), to: p(900, 330))
            let kinds = model.listItems.map(\.kind)
            context.check("blur and pixelate are cosmetic effects", model.document.obfuscations.count == 2)
            context.check(
                "only the redaction is labeled secure",
                kinds.filter(\.isSecure) == [.redaction] && kinds.filter(\.isCosmetic).count == 2, "\(kinds)")
            if let blur = model.document.obfuscations.first { model.select(.obfuscation(blur.id)) }
            await E2EActions.snapshotEditor(controller, context, shot: "editor")

            let url = harness.output.workDirectory.appending(path: "redaction-export.png")
            let outcome = await E2EActions.export(controller, .save(url, overwriteConfirmed: false))
            try context.require("export saved the PNG", outcome == .saved(url), "\(outcome)")
            let data = try Data(contentsOf: url)
            let decoded = try E2EActions.decode(data, "export", context)
            let mx = Int(mask.outputRect.minX), my = Int(mask.outputRect.minY)
            var uncovered = 0
            for y in my..<Int(mask.outputRect.maxY) {
                for x in mx..<Int(mask.outputRect.maxX) where decoded.pixel(x: x, y: y) != ChartFixture.Color(0, 0, 0) {
                    uncovered += 1
                }
            }
            context.check(
                "every masked pixel is solid black in the export", uncovered == 0, "\(uncovered) pixels differ")
            context.check(
                "the export carries no secret text", !ContainerInspector.contains("sk-live", in: data))
            try await redOnePair(harness, context)
        }

        /// RED-01 through the app: same mask and recipe on a secret pair; the exports must decode
        /// identically, and without the mask they must differ.
        static func redOnePair(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let secret = FixtureRect(x: 96, y: 88, width: 280, height: 48)
            let pair: SecretPair
            do {
                pair = try SecretPairFixture.make(width: 480, height: 240, secret: secret, seed: 0x5EC2E7)
            } catch {
                throw E2EAbort("secret pair fixture failed: \(error)")
            }
            func exported(_ image: CGImage, name: String, masked: Bool) async throws -> (Data, DecodedPixels) {
                let controller = try await harness.openImported(image, name: "\(name).png")
                let model = controller.model
                let p = E2EActions.point
                if masked {
                    E2EActions.drag(
                        model, .redact, from: p(Double(secret.x), Double(secret.y)),
                        to: p(Double(secret.maxX), Double(secret.maxY)))
                }
                E2EActions.drag(model, .arrow, from: p(20, 220), to: p(200, 40))
                model.setCrop(Rect(x: 8, y: 8, width: 464, height: 224))
                model.setResizeScale(0.5)
                let url = harness.output.workDirectory.appending(path: "\(name)-export.png")
                let outcome = await model.export(.save(url, overwriteConfirmed: false))
                guard outcome == .saved(url) else { throw E2EAbort("\(name) export: \(outcome)") }
                let data = try Data(contentsOf: url)
                controller.window?.close()
                return (data, try E2EActions.decode(data, name, context))
            }
            let maskedA = try await exported(pair.a, name: "red01-a-masked", masked: true)
            let maskedB = try await exported(pair.b, name: "red01-b-masked", masked: true)
            context.check(
                "RED-01: masked exports of the secret pair decode to identical pixels", maskedA.1 == maskedB.1,
                "\(maskedA.1.width)×\(maskedA.1.height); differing bytes: \(zip(maskedA.1.bytes, maskedB.1.bytes).filter { $0 != $1 }.count)"
            )
            context.check(
                "RED-01: masked exports are byte-identical files", maskedA.0 == maskedB.0,
                "\(maskedA.0.count) vs \(maskedB.0.count) bytes")
            let plainA = try await exported(pair.a, name: "red01-a-plain", masked: false)
            let plainB = try await exported(pair.b, name: "red01-b-plain", masked: false)
            context.check(
                "RED-01 control: without the mask the exports differ", plainA.1 != plainB.1,
                "differing bytes: \(zip(plainA.1.bytes, plainB.1.bytes).filter { $0 != $1 }.count)")
        }

        static func cropResize(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let chart: CGImage
            do { chart = try ChartFixture.geometryChart(width: 800, height: 600) } catch {
                throw E2EAbort("geometry chart: \(error)")
            }
            let controller = try await harness.openImported(chart, name: "geometry-chart.png")
            let model = controller.model
            let p = E2EActions.point
            E2EActions.drag(model, .crop, from: p(100, 50), to: p(700, 450))
            context.check(
                "the crop tool sets a 600 × 400 crop",
                model.document.crop == Rect(x: 100, y: 50, width: 600, height: 400),
                "\(String(describing: model.document.crop))")
            model.setResizeScale(0.5)
            let size = model.document.outputPixelSize(exportScale: 1)
            context.check(
                "output size is 300 × 200 at 50%", size == PixelSize(width: 300, height: 200),
                "\(size.width) × \(size.height)")
            model.selectTool(.select)
            await E2EActions.snapshotEditor(controller, context, shot: "crop")

            let url = harness.output.workDirectory.appending(path: "crop-resize.png")
            let outcome = await E2EActions.export(controller, .save(url, overwriteConfirmed: false))
            try context.require("export saved", outcome == .saved(url), "\(outcome)")
            let decoded = try E2EActions.decode(try Data(contentsOf: url), "crop export", context)
            context.check(
                "exported file is 300 × 200 pixels", decoded.width == 300 && decoded.height == 200,
                "\(decoded.width) × \(decoded.height)")
            let colors = ChartFixture.quadrantColors
            let corners = [
                (decoded.pixel(x: 10, y: 10), colors[0]), (decoded.pixel(x: 290, y: 10), colors[1]),
                (decoded.pixel(x: 10, y: 190), colors[2]), (decoded.pixel(x: 290, y: 190), colors[3]),
            ]
            context.check(
                "each output corner keeps its source quadrant color",
                corners.allSatisfy { E2EActions.distance($0.0, $0.1) <= 2 },
                corners.map { "\($0.0.hex)/\($0.1.hex)" }.joined(separator: " "))
            model.setShowsOutputPreview(true)
            await E2EActions.snapshotEditor(controller, context, shot: "output-preview")
        }

        static func pixelTools(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let chart: CGImage
            do { chart = try ChartFixture.colorChart(cell: 96) } catch { throw E2EAbort("color chart: \(error)") }
            let controller = try await harness.openImported(chart, name: "color-chart.png")
            let model = controller.model
            let p = E2EActions.point
            let cell = 96.0
            func center(_ index: Int) -> Point<DocumentSpace> {
                p(Double(index % 4) * cell + cell / 2, Double(index / 4) * cell + cell / 2)
            }

            model.selectTool(.loupe)
            model.pointerMoved(to: center(5))
            let inspected = try context.unwrap("the loupe samples a pixel", model.inspection)
            context.check(
                "loupe reads cell 6 as #FEDCBA", inspected.hex == ChartFixture.chartColors[5].hex, inspected.hex)
            let loupe = try context.unwrap("loupe pixels", model.loupe(radius: 7))
            let loupePixels = try E2EActions.pixels(of: loupe.image, "loupe", context)
            let uniform = Set(loupePixels.bytes.chunked4()).count == 1
            context.check(
                "loupe is a 15 × 15 nearest-neighbor crop with no interpolation",
                loupe.image.width == 15 && loupe.image.height == 15 && uniform,
                "\(loupe.image.width)×\(loupe.image.height), uniform: \(uniform)")
            await E2EActions.snapshotEditor(controller, context, shot: "loupe")

            E2EActions.drag(model, .ruler, from: p(20.4, 30.2), to: p(260, 130))
            let ruler = try context.unwrap("the ruler measures", model.ruler)
            context.check(
                "ruler distance is 260 px (240 × 100)",
                ruler.dxPixels == 240 && ruler.dyPixels == 100 && ruler.distancePixels == 260,
                "\(ruler.dxPixels) × \(ruler.dyPixels), \(ruler.distancePixels)")
            context.check("an imported image has no point scale", ruler.pointPixelScale == nil)
            model.setZoom(model.viewport.zoom * 2)
            context.check("zoom does not change the measurement", model.ruler == ruler)
            model.zoomToFit()
            await E2EActions.snapshotEditor(controller, context, shot: "ruler")

            E2EActions.click(model, .colorPicker, at: center(3))
            let picked = try context.unwrap("the color picker samples", model.pickedColor)
            context.check("picker reads cell 4 as #1A2B3C", picked.hex == "#1A2B3C", picked.hex)
            context.check("RGB text is decimal sRGB", picked.rgbText == "26 43 60", picked.rgbText)
            context.check("Copy HEX succeeds", model.copyPickedColor(asHex: true))
            context.check(
                "the private text pasteboard holds the HEX",
                harness.textPasteboard.string(forType: .string) == "#1A2B3C",
                String(describing: harness.textPasteboard.string(forType: .string)))
            await E2EActions.snapshotEditor(controller, context, shot: "color-picker")
        }

        static func composition(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let controller = try await E2EActions.captureRegion(
                harness, CGRect(x: 200, y: 140, width: 400, height: 300), context)
            let model = controller.model
            let second: CGImage, third: CGImage
            do {
                second = try ChartFixture.geometryChart(width: 400, height: 300)
                third = try ChartFixture.colorChart(cell: 50)
            } catch { throw E2EAbort("charts: \(error)") }
            for (image, name) in [(second, "layer-2.png"), (third, "layer-3.png")] {
                let url = harness.output.workDirectory.appending(path: name)
                try E2EDrawing.png(image).write(to: url, options: .atomic)
                let added = await model.addImageLayer(from: .file(url))
                context.check("\(name) is added as a layer", added)
            }
            try context.require(
                "three image layers", model.document.layers.count == 3, "\(model.document.layers.count)")
            model.arrangeSideBySide()
            let spacing = EditorModel.sideBySideSpacing
            context.check(
                "side by side: height of the first image, widths in aspect",
                model.document.canvasSize == Size(width: 800 + spacing + 800 + spacing + 1200, height: 600),
                "\(model.document.canvasSize)")
            var aspectOK = true
            for layer in model.document.layers {
                guard let asset = model.document.assets[layer.assetID] else { continue }
                let bounds = layer.documentBounds(assetSize: asset.pixelSize)
                let ratio = Double(asset.pixelSize.width) / Double(asset.pixelSize.height)
                if abs(bounds.width / bounds.height - ratio) > 0.001 { aspectOK = false }
            }
            context.check("no layer is stretched", aspectOK)
            let middle = model.document.layers[1].id
            model.setLayerOpacity(0.6, for: middle)
            context.check("layer opacity is 60%", model.document.layers[1].opacity == 0.6)

            model.setBackground(
                .linearGradient(from: RGBA(r: 90, g: 120, b: 220), to: RGBA(r: 170, g: 90, b: 200), angleDegrees: 135))
            model.setPadding(48)
            model.setCornerRadius(24)
            model.setShadow(Presentation.Shadow())
            let p = E2EActions.point
            E2EActions.drag(model, .spotlight, from: p(900, 100), to: p(1500, 500))
            E2EActions.drag(model, .magnifier, from: p(60, 60), to: p(220, 180))
            let callouts = model.document.callouts.map { callout -> String in
                if case .spotlight = callout.kind { return "spotlight" }
                return "magnifier"
            }
            context.check("spotlight and magnifier callouts", callouts == ["spotlight", "magnifier"], "\(callouts)")
            model.clearSelection()
            model.selectTool(.select)

            let expected = PixelSize(width: 2848 + 96, height: 600 + 96)
            context.check(
                "output size includes 48 px padding on each side",
                model.document.outputPixelSize(exportScale: 1) == expected,
                "\(model.document.outputPixelSize(exportScale: 1))")
            let url = harness.output.workDirectory.appending(path: "composition.png")
            let outcome = await E2EActions.export(controller, .save(url, overwriteConfirmed: false))
            try context.require("composition exported", outcome == .saved(url), "\(outcome)")
            let decoded = try E2EActions.decode(try Data(contentsOf: url), "composition", context)
            context.check(
                "exported size and aspect match the document",
                decoded.width == expected.width && decoded.height == expected.height,
                "\(decoded.width) × \(decoded.height)")
            let corner = decoded.pixel(x: 4, y: decoded.height / 2)
            context.check("the padding shows the gradient background", corner.a == 255 && corner.b > 150, corner.hex)
            model.setShowsOutputPreview(true)
            await E2EActions.snapshotEditor(controller, context, shot: "output-preview")
        }
    }

    extension Array where Element == UInt8 {
        /// Groups bytes into RGBA quadruples for set comparisons.
        func chunked4() -> [[UInt8]] {
            stride(from: 0, to: count - 3, by: 4).map { Array(self[$0..<($0 + 4)]) }
        }
    }
#endif
