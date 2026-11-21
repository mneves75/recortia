#if DEBUG
    import AppKit
    import Domain
    import Features
    import ImageIO
    import RecortiaFixtures

    /// B-9a through the real app: a synthetic capture saved as HEIC into a folder the runner owns,
    /// and File › Print… handing the sanitized PNG to a recording print sink that builds the real
    /// print operation but never shows a panel.
    @MainActor
    enum HEICPrintScenarios {
        static func heicAndPrint(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let controller = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            defer { harness.editors.closeAll() }
            let model = controller.model
            let copied = await E2EActions.export(controller, .copy)
            try context.require("Copy succeeds", copied == .copied, "\(copied)")
            let png = try context.unwrap(
                "PNG on the private pasteboard", harness.clipboard.pasteboard.data(forType: .png))
            let copyPixels = try E2EActions.decode(png, "copied PNG", context)

            let formatBefore = harness.settings.preferences.exportFormat
            harness.settings.update { $0.exportFormat = .heic }
            defer { harness.settings.update { $0.exportFormat = formatBefore } }
            if harness.settings.encodesHEIC {
                try await saveHEIC(controller, size: copyPixels, harness, context)
            } else {
                context.check(
                    "without a HEIC encoder the stored HEIC choice saves PNG",
                    harness.settings.exportOptions.formatChoice == .fixed(.png)
                        && harness.settings.preferences.exportFormat == .heic,
                    "\(harness.settings.exportOptions.formatChoice)")
            }

            let window = try context.unwrap("editor window", controller.window)
            try await E2EAccessibilityControl.showAndActivate(window, context)
            if let canvas = controller.canvasView { window.makeFirstResponder(canvas) }
            let title = String(localized: "Print…", table: "Editor")
            try context.require(
                "Print… is enabled for the key editor",
                await E2EWait.until(timeout: .seconds(3)) {
                    EditorToolbarScenarios.viewCommand(title)?.isEnabled == true
                }, "editor key: \(window.isKeyWindow), can export: \(model.canStartExport)")
            let item = try context.unwrap("File has Print…", EditorToolbarScenarios.viewCommand(title))
            context.check(
                "Print… is ⌘P",
                item.keyEquivalent == "p"
                    && item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command,
                "\(item.keyEquivalent.debugDescription) \(item.keyEquivalentModifierMask.rawValue)")
            let before = harness.printer.snapshots.count
            let menu = try context.unwrap("Print… has a menu", item.menu)
            menu.performActionForItem(at: menu.index(of: item))
            try context.require(
                "File › Print… hands one snapshot to the print sink",
                await E2EWait.until(timeout: .seconds(10)) { harness.printer.snapshots.count == before + 1 },
                "\(harness.printer.snapshots.count - before)")
            let snapshot = harness.printer.snapshots[before]
            context.check(
                "the printed snapshot is this editor's PNG",
                snapshot.format == .png && snapshot.documentID == model.document.id, "\(snapshot.format)")
            let printed = try E2EActions.decode(snapshot.bytes, "printed PNG", context)
            context.check("the print sink gets the pixels Copy published", printed == copyPixels)
            let operation = harness.printer.operations[before]
            let view = operation.view as? NSImageView
            let representation = view?.image?.representations.first as? NSBitmapImageRep
            context.check(
                "the print operation shows only that image, at its pixel size",
                view?.image?.representations.count == 1 && representation?.pixelsWide == snapshot.pixelSize.width
                    && representation?.pixelsHigh == snapshot.pixelSize.height,
                "\(representation?.pixelsWide ?? 0) × \(representation?.pixelsHigh ?? 0)")
            context.check(
                "the image is fit to the page and centred",
                operation.printInfo.horizontalPagination == .fit && operation.printInfo.verticalPagination == .fit
                    && operation.printInfo.isHorizontallyCentered && operation.printInfo.isVerticallyCentered)
            context.check(
                "printing reports the hand-off", model.notice == .exported(.printed),
                String(describing: model.notice))
        }

        private static func saveHEIC(
            _ controller: EditorWindowController, size: DecodedPixels, _ harness: E2EHarness,
            _ context: ScenarioContext
        ) async throws {
            let options = harness.settings.exportOptions
            let quality = harness.settings.preferences.jpegQuality
            context.check(
                "HEIC is the saved-file format at the shared quality",
                options.formatChoice == .fixed(.heic(quality: quality)), "\(options.formatChoice)")
            let folder = harness.output.workDirectory.appending(path: "heic-saves", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: "capture.heic")
            let saved = await controller.saveImage(to: url, format: options.formatChoice)
            try context.require("Save as HEIC succeeds", saved == .saved(url), "\(saved)")
            let data = try Data(contentsOf: url)
            let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) }
            context.check("the saved file is HEIC", type as String? == "public.heic", "\(String(describing: type))")
            do {
                let items = try ContainerInspector.heicStructure(data).itemTypes
                context.check(
                    "the HEIC holds image items only", !items.isEmpty && Set(items).isSubset(of: ["hvc1", "grid"]),
                    items.joined(separator: " "))
            } catch {
                context.check("the HEIC structure parses", false, "\(error)")
            }
            let pixels = try E2EActions.decode(data, "saved HEIC", context)
            context.check(
                "the HEIC decodes at the copied image's size",
                pixels.width == size.width && pixels.height == size.height,
                "\(pixels.width) × \(pixels.height), expected \(size.width) × \(size.height)")
        }
    }
#endif
