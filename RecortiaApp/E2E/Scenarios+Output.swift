#if DEBUG
    import AppKit
    import Domain
    import Features
    import Imaging
    import RecortiaFixtures
    import Synchronization

    /// Counts actual PNG materialization, rather than type discovery, on a private pasteboard.
    nonisolated final class SyntheticDropDataProvider: NSObject, NSPasteboardItemDataProvider {
        private let png: Data
        private let requests = Mutex(0)
        var dataRequests: Int { requests.withLock { $0 } }

        init(png: Data) { self.png = png }

        func pasteboard(
            _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
        ) {
            requests.withLock { $0 += 1 }
            item.setData(png, forType: type)
        }
    }

    /// Only the private pasteboard and destination window are meaningful for this synthetic drag.
    @MainActor
    final class SyntheticCanvasDrag: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingDestinationWindow: NSWindow?
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        nonisolated var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }

        init(pasteboard: NSPasteboard, window: NSWindow?) {
            draggingPasteboard = pasteboard
            draggingDestinationWindow = window
        }

        func slideDraggedImage(to screenPoint: NSPoint) {}
        nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func resetSpringLoading() {}
        func enumerateDraggingItems(
            options: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
    }

    /// Holds a synthetic file read so the real app's admission decisions are observable.
    /// Paste never reads the user's general pasteboard in this runner.
    @MainActor
    final class SyntheticImportInput: ImageInputService {
        private let input: any ImageInputService
        var holdNextRead = false
        private var waiter: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { waiter != nil }
        private(set) var fileReads = 0
        private(set) var pasteboardReads = 0

        init(input: any ImageInputService) { self.input = input }

        func readFile(at url: URL) async throws(ImportError) -> Data {
            fileReads += 1
            if holdNextRead {
                holdNextRead = false
                await withCheckedContinuation { waiter = $0 }
            }
            return try await input.readFile(at: url)
        }

        func readPasteboardImage() -> Data? {
            pasteboardReads += 1
            return nil
        }

        func release() {
            waiter?.resume()
            waiter = nil
        }
    }

    @MainActor
    enum OutputScenarios {
        /// PNG chunks the export pipeline may write (Imaging's ExportEncoder allowlist).
        static let allowedPNGChunks: Set<String> = [
            "IHDR", "PLTE", "tRNS", "sRGB", "iCCP", "gAMA", "cHRM", "IDAT", "IEND",
        ]

        static func exportSinks(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
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
            let collision = folder.appending(path: "consent.png")
            let original = Data("existing owner file".utf8)
            try original.write(to: collision)
            var confirmations = 0
            let declined = await controller.saveImage(to: collision) {
                confirmations += 1
                return false
            }
            context.check("replacement decline cancels the save", declined == .canceled)
            context.check("a collision asks before overwriting", confirmations == 1)
            context.check("declining preserves the existing bytes", try Data(contentsOf: collision) == original)
            let replaced = await controller.saveImage(to: collision) {
                confirmations += 1
                return true
            }
            context.check("explicit replacement saves", replaced == .saved(collision) && confirmations == 2)
            context.check(
                "replacement uses sanitized export pixels",
                try E2EActions.decode(Data(contentsOf: collision), "replacement", context) == savedPixels)
            let fresh = folder.appending(path: "no-collision.png")
            let created = await controller.saveImage(to: fresh) {
                confirmations += 1
                return false
            }
            context.check(
                "exclusive new save needs no replacement consent", created == .saved(fresh) && confirmations == 2)
            let beforeNative = try Data(contentsOf: collision)
            let nativeSave = Task { await controller.saveImage(to: collision) }
            let sheetAppeared = await E2EWait.until { controller.window?.attachedSheet != nil }
            try context.require("collision presents the native replacement sheet", sheetAppeared)
            let sheet = try context.unwrap("replacement sheet", controller.window?.attachedSheet)
            let content = try context.unwrap("replacement sheet content", sheet.contentView)
            await E2ESnapshot.settle(content)
            context.snapshot(content, shot: "replacement-consent")
            let buttons = EditorWindowController.all(NSButton.self, in: content)
            let cancel = try context.unwrap(
                "replacement Cancel button",
                buttons.first {
                    $0.title == String(localized: "Cancel", table: "Editor")
                })
            cancel.performClick(nil)
            let nativeOutcome = await nativeSave.value
            let afterNative = try Data(contentsOf: collision)
            context.check(
                "native Cancel leaves the saved file unchanged",
                nativeOutcome == .canceled && afterNative == beforeNative)

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
            // Reading the general pasteboard cannot show which app wrote it; assert the injected sink.
            context.check(
                "Copy used a private pasteboard, never the general one", harness.clipboard.pasteboard.name != .general,
                harness.clipboard.pasteboard.name.rawValue)
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

            // PIN-02: copy and drag-out export the pinned sanitized raster through the pipeline, the
            // same bytes as the editor's own 1x copy; opacity and zoom are display only.
            context.check("a pin rendered from a document can be exported", pin.exportID != nil)
            let pinCopy = await pins.export(.copy, pin.id)
            try context.require("Copy from a pin succeeds", pinCopy == .copied, "\(pinCopy)")
            let board = harness.clipboard.pasteboard
            context.check(
                "the pin's copy stores only PNG", board.pasteboardItems?.first?.types == [.png],
                board.pasteboardItems?.first?.types.map(\.rawValue).joined(separator: ", ") ?? "none")
            let pinBytes = try context.unwrap("the pin's PNG on the pasteboard", board.data(forType: .png))
            let editorCopy = await E2EActions.export(controller, .copy)
            try context.require("the editor's copy succeeds", editorCopy == .copied, "\(editorCopy)")
            let editorBytes = try context.unwrap("the editor's PNG on the pasteboard", board.data(forType: .png))
            context.check("the pin copies exactly the editor's 1x export", pinBytes == editorBytes)
            let filesBefore = harness.drag.deliveredFiles.count
            let pinDrag = await pins.export(.drag, pin.id)
            context.check("Drag Out from a pin delivers a file", pinDrag == .dragged, "\(pinDrag)")
            let dropped = try context.unwrap(
                "the receiver got the pin's file",
                harness.drag.deliveredFiles.count == filesBefore + 1 ? harness.drag.deliveredFiles.last : nil)
            context.check("the dropped file holds the same bytes", (try? Data(contentsOf: dropped)) == pinBytes)

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

        static func importAdmission(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let controller = try await harness.openImported(harness.desktop, name: "admission.png")
            let model = controller.model
            let url = harness.output.workDirectory.appending(path: "admission.png")
            let input = harness.importInput
            let initialEditors = harness.editors.controllers.count
            let initialReads = input.fileReads
            let initialMessages = harness.messages.values.count
            input.holdNextRead = true
            defer { input.release() }
            harness.app.importImage(from: .file(url))
            let started = await E2EWait.until { input.isWaiting }
            try context.require("new-document read is suspended", started)
            context.check("Open Image is disabled during import", !harness.app.isEnabled(.openImage))
            context.check("Paste Image is disabled during import", !harness.app.isEnabled(.pasteImage))
            let rejected = await model.addImageLayer(from: .pasteboard)
            context.check("layer import shares the app's busy slot", !rejected && model.notice == .importFailed(.busy))
            context.check("busy Paste never reads the clipboard", input.pasteboardReads == 0)
            let canvas = try context.unwrap("real editor canvas", controller.canvasView)
            let droppedPNG = try E2EDrawing.png(harness.desktop)
            let busyProvider = SyntheticDropDataProvider(png: droppedPNG)
            let busyBoard = NSPasteboard.withUniqueName()
            defer { busyBoard.releaseGlobally() }
            let busyItem = NSPasteboardItem()
            try context.require("busy PNG data is promised", busyItem.setDataProvider(busyProvider, forTypes: [.png]))
            try context.require("private busy drop is installed", busyBoard.writeObjects([busyItem]))
            let busyDrag = SyntheticCanvasDrag(pasteboard: busyBoard, window: controller.window)
            context.check("raw PNG hover accepts the type", canvas.draggingEntered(busyDrag) == .copy)
            context.check("hover does not request PNG bytes", busyProvider.dataRequests == 0)
            let noticesBeforeDrop = model.noticeSerial
            _ = canvas.performDragOperation(busyDrag)
            let dropRejected = await E2EWait.until {
                model.noticeSerial > noticesBeforeDrop && model.notice == .importFailed(.busy)
            }
            context.check("busy canvas drop is rejected", dropRejected)
            context.check(
                "busy canvas drop never requests PNG bytes", busyProvider.dataRequests == 0,
                "requests: \(busyProvider.dataRequests)")
            context.check("busy canvas drop creates no layer", model.document.layers.count == 1)
            for _ in 0..<16 { harness.app.importImage(from: .file(url)) }
            let reported = await E2EWait.until { harness.messages.values.count == initialMessages + 16 }
            context.check("all excess app requests report busy", reported)
            context.check("excess requests perform no file reads", input.fileReads == initialReads + 1)
            context.check("rejections leave the original import active", harness.features.importer.isImporting)
            context.check(
                "no editor opens before the admitted read finishes", harness.editors.controllers.count == initialEditors
            )
            if let root = controller.window?.contentView {
                await E2ESnapshot.settle(root)
                context.snapshot(root, shot: "busy-layer")
            }
            input.release()
            _ = try await E2EActions.waitForNewEditor(harness, after: initialEditors, context)
            context.check(
                "only the admitted request opened an editor", harness.editors.controllers.count == initialEditors + 1)
            context.check(
                "successful completion restores Open and Paste",
                harness.app.isEnabled(.openImage) && harness.app.isEnabled(.pasteImage))

            input.holdNextRead = true
            let layer = Task { await model.addImageLayer(from: .file(url)) }
            let layerStarted = await E2EWait.until { input.isWaiting }
            try context.require("layer read is suspended", layerStarted)
            let messagesBefore = harness.messages.values.count
            harness.app.importImage(from: .file(url))
            let appRejected = await E2EWait.until { harness.messages.values.count == messagesBefore + 1 }
            context.check("app import shares the layer's busy slot", appRejected)
            context.check("only one read per admitted operation", input.fileReads == initialReads + 2)
            layer.cancel()
            context.check("cancellation retains the slot until the reader exits", harness.features.importer.isImporting)
            input.release()
            context.check(
                "cancelled layer is discarded", await layer.value == false && model.document.layers.count == 1)
            context.check("cancellation releases the slot", !harness.features.importer.isImporting)
            let retried = await model.addImageLayer(from: .file(url))
            context.check("a later layer import succeeds", retried && model.document.layers.count == 2)
            if let root = controller.window?.contentView {
                await E2ESnapshot.settle(root)
                context.snapshot(root, shot: "retry-layer")
            }
            let admittedProvider = SyntheticDropDataProvider(png: droppedPNG)
            let admittedBoard = NSPasteboard.withUniqueName()
            defer { admittedBoard.releaseGlobally() }
            let admittedItem = NSPasteboardItem()
            try context.require(
                "admitted PNG data is promised", admittedItem.setDataProvider(admittedProvider, forTypes: [.png]))
            try context.require("private admitted drop is installed", admittedBoard.writeObjects([admittedItem]))
            let admittedDrag = SyntheticCanvasDrag(pasteboard: admittedBoard, window: controller.window)
            context.check("admitted PNG hover accepts the type", canvas.draggingEntered(admittedDrag) == .copy)
            context.check("admitted hover does not request bytes", admittedProvider.dataRequests == 0)
            context.check("admitted canvas drop starts", canvas.performDragOperation(admittedDrag))
            let dropAdded = await E2EWait.until { model.document.layers.count == 3 }
            context.check("admitted canvas drop adds one layer", dropAdded)
            context.check(
                "admitted canvas drop requests PNG bytes", admittedProvider.dataRequests > 0,
                "requests: \(admittedProvider.dataRequests)")
            if let root = controller.window?.contentView {
                await E2ESnapshot.settle(root)
                context.snapshot(root, shot: "admitted-drop")
            }
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
