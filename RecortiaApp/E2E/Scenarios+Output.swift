#if DEBUG
    import AppKit
    import Domain
    import Features
    import Imaging
    import RecortiaFixtures

    /// Export sinks, pins, and import (FR-03, FR-07, FR-09, IO-01, EXP-01, RED-02, PIN-01).
    @MainActor
    enum OutputScenarios {
        /// PNG chunks the export pipeline may write (Imaging's ExportEncoder allowlist).
        static let allowedPNGChunks: Set<String> = [
            "IHDR", "PLTE", "tRNS", "sRGB", "iCCP", "gAMA", "cHRM", "IDAT", "IEND",
        ]

        static func exportSinks(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let generalBefore = NSPasteboard.general.changeCount
            let controller = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            let model = controller.model
            E2EActions.drag(model, .arrow, from: E2EActions.point(100, 700), to: E2EActions.point(500, 420))
            context.check("an edited document is dirty", model.isDirty)

            // Copy: the private pasteboard receives exactly one PNG representation.
            let copied = await E2EActions.export(controller, .copy)
            try context.require("Copy succeeds", copied == .copied, "\(copied)")
            let pasteboard = harness.clipboard.pasteboard
            let items = pasteboard.pasteboardItems ?? []
            context.check("the pasteboard holds one item", items.count == 1, "\(items.count)")
            context.check(
                "the item stores only PNG", items.first?.types == [.png],
                items.first?.types.map(\.rawValue).joined(separator: ", ") ?? "none")
            let copyData = try context.unwrap("PNG data on the pasteboard", pasteboard.data(forType: .png))
            let copyPixels = try E2EActions.decode(copyData, "clipboard PNG", context)
            context.check("the export clears the dirty flag", !model.isDirty)

            // Save to the preferred folder under the output directory.
            let folder = harness.output.workDirectory.appending(path: "saves", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bookmark = try folder.bookmarkData()
            harness.settings.update { $0.preferredSaveFolderBookmark = bookmark }
            defer { harness.settings.update { $0.preferredSaveFolderBookmark = nil } }
            let saved = await E2EActions.export(controller, .saveToPreferredFolder)
            guard case .saved(let url) = saved else {
                try context.require("Save to Preferred Folder succeeds", false, "\(saved)")
                return
            }
            context.check(
                "the file is in the preferred folder",
                url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path, url.path)
            context.check(
                "the saved file exists", FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
            context.check(
                "the filename carries no window title",
                !url.lastPathComponent.contains("Quarterly") && !url.lastPathComponent.contains("Notes"),
                url.lastPathComponent)
            let savedData = try Data(contentsOf: url)
            do {
                let chunks = try ContainerInspector.pngChunkTypes(savedData)
                context.check(
                    "PNG chunks are within the allowlist", Set(chunks).isSubset(of: allowedPNGChunks),
                    chunks.joined(separator: " "))
            } catch {
                context.check("PNG chunks parse with valid CRCs", false, "\(error)")
            }
            let savedPixels = try E2EActions.decode(savedData, "saved PNG", context)

            // Drag out: the real chip panel, and the real file promise fulfilled into a folder.
            let dragged = await E2EActions.export(controller, .drag)
            try context.require("Drag Out completes", dragged == .dragged, "\(dragged)")
            let dropped = try context.unwrap("the file promise was written", harness.drag.deliveredFiles.last)
            let dropPixels = try E2EActions.decode(try Data(contentsOf: dropped), "dragged file", context)
            context.check(
                "copy, save, and drag carry identical pixels", copyPixels == savedPixels && savedPixels == dropPixels,
                "\(copyPixels.width)×\(copyPixels.height)")
            if let chip = harness.drag.panel?.contentView {
                await E2ESnapshot.settle(chip)
                context.snapshot(chip, shot: "drag-chip")
            } else {
                context.check("the drag chip panel was built", false)
            }
            context.check(
                "the general pasteboard was never written", NSPasteboard.general.changeCount == generalBefore,
                "changeCount \(generalBefore) → \(NSPasteboard.general.changeCount)")
            await E2EActions.snapshotEditor(controller, context, shot: "editor")
        }

        static func pins(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let pins = harness.features.pins
            let controller = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            let model = controller.model
            await model.pin()
            context.check("pinning succeeds", model.notice == .pinned, "\(String(describing: model.notice))")
            let pin = try context.unwrap("one pin exists", pins.pins.first)
            context.check("the pin shows the capture at its point size", pin.displayScale == 2, "\(pin.displayScale)")
            context.check("new pins use the default opacity", pin.opacity == 1, "\(pin.opacity)")
            context.check("Bring Pins Forward is enabled", harness.app.isEnabled(.bringPinsForward))
            pins.setOpacity(0.6, for: pin.id)
            context.check("opacity changes to 60%", pins.pin(for: pin.id)?.opacity == 0.6)

            // The pin's real SwiftUI content from the live model. The real `PinPanel` around it is
            // exercised in a child process (below), because it can end the process.
            let host = E2ESnapshot.host(PinContentView(pinID: pin.id, model: pins, fitScale: 1))
            defer { host.close() }
            let root = try context.unwrap("pin content hosted", host.contentView)
            await E2ESnapshot.settle(root)
            context.snapshot(root)
            await E2EPanelProbe.check(.pin, context)

            // A redaction changes the privacy epoch: pins of the old epoch are removed.
            let notes = SyntheticDesktop.notesWindow
            let secret = SyntheticDesktop.secretRect.offsetBy(dx: -notes.minX, dy: -notes.minY)
            E2EActions.drag(
                model, .redact, from: E2EActions.point(secret.minX * 2, secret.minY * 2),
                to: E2EActions.point(secret.maxX * 2, secret.maxY * 2))
            context.check("the privacy change removes the stale pin", pins.pins.isEmpty, "\(pins.pins.count) pins")
            context.check(
                "the editor says the pin was closed", model.notice == .pinsInvalidated(1),
                "\(String(describing: model.notice))")
            await model.pin()
            let repinned = try context.unwrap("a new pin after the redaction", pins.pins.first)
            let pixels = try E2EActions.pixels(of: repinned.image, "new pin", context)
            let center = pixels.pixel(x: Int(secret.midX * 2), y: Int(secret.midY * 2))
            context.check("the new pin shows the redaction", center == ChartFixture.Color(0, 0, 0), center.hex)
        }

        static func importFiles(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let importer = harness.features.importer
            let chart: CGImage
            do { chart = try ChartFixture.geometryChart(width: 320, height: 240) } catch {
                throw E2EAbort("chart: \(error)")
            }
            let png = try await harness.openImported(chart, name: "import-valid.png")
            let asset = try context.unwrap("imported asset", png.model.document.assets.values.first)
            context.check("PNG imports as an imported asset", asset.origin == .imported)
            context.check("PNG size is 320 × 240", asset.pixelSize == PixelSize(width: 320, height: 240))
            context.check("an imported image has no screen scale", png.model.measurementPointScale == nil)

            let jpegURL = harness.output.workDirectory.appending(path: "import-valid.jpg")
            try E2EDrawing.jpeg(chart).write(to: jpegURL, options: .atomic)
            let before = harness.editors.controllers.count
            let jpeg = await importer.importImage(from: .file(jpegURL))
            context.check("JPEG imports", (try? jpeg.get()) != nil, "\(jpeg)")
            let jpegEditor = try await E2EActions.waitForNewEditor(harness, after: before, context)
            context.check(
                "JPEG opens in the editor at 320 × 240",
                jpegEditor.model.document.canvasSize == Size(width: 320, height: 240))
            await E2EActions.snapshotEditor(jpegEditor, context, shot: "jpeg")

            let oversized: Data
            do { oversized = try ContainerCrafting.blankOneBitPNG(width: 8_000, height: 6_000) } catch {
                throw E2EAbort("oversized fixture: \(error)")
            }
            let pngData = try E2EDrawing.png(chart)
            let cases: [(String, Data, ImportFailure)] = [
                ("oversized", oversized, .tooManyPixels),
                ("corrupt", pngData.prefix(pngData.count / 3), .corrupt),
            ]
            for (name, data, expected) in cases {
                let url = harness.output.workDirectory.appending(path: "import-\(name).png")
                try data.write(to: url, options: .atomic)
                let count = harness.editors.controllers.count
                let result = await importer.importImage(from: .file(url))
                guard case .failure(let failure) = result else {
                    context.check("\(name) file is rejected", false, "imported")
                    continue
                }
                context.check("\(name) file is rejected as \(expected)", failure == expected, "\(failure)")
                context.check("\(name) opens no editor", harness.editors.controllers.count == count)
                context.check(
                    "\(name) leaves the source file untouched", (try? Data(contentsOf: url)) == data)
                let message = UserMessage.importFailure(failure)
                let alert = NSAlert()
                alert.messageText = message.title
                alert.informativeText = message.detail
                alert.alertStyle = .informational
                alert.addButton(withTitle: String(localized: "OK"))
                alert.layout()
                E2ESnapshot.park(alert.window)
                if let root = alert.window.contentView {
                    await E2ESnapshot.settle(root)
                    context.snapshot(root, shot: "\(name)-error")
                }
                alert.window.close()
            }
        }
    }
#endif
