#if DEBUG
    import AppKit
    import Domain
    import Features
    import KeyboardShortcuts
    import MacPlatform

    /// The real composition root for the run: `AppServices.live()` with the synthetic replacements,
    /// a real `AppModel` (never launched, so no onboarding and no global shortcut handlers), and the same
    /// wiring `AppModel.wire` performs, except that editor windows are parked offscreen instead
    /// of being presented.
    @MainActor
    final class E2EHarness {
        let output: E2EOutput
        let settings: SettingsStore
        let desktop: CGImage
        let capture: SyntheticCaptureService
        let permission: SyntheticScreenPermission
        let scrollFrames: SyntheticScrollFrames
        let clipboard: PrivatePasteboardClipboard
        let textPasteboard: NSPasteboard
        let drag: SyntheticDragReceiver
        let github = SyntheticGitHubUpload()
        let exportGate: SyntheticExportGate
        let importInput: SyntheticImportInput
        let links = RecordingLinkOpener()
        let messages = RecordingMessagePresenter()
        let services: AppServices
        let app: AppModel
        let features: FeatureModels
        let editors: E2EEditorHost
        let environment: EditorEnvironment
        /// The macOS shortcuts the runner treats as enabled, so shortcut states never depend on the
        /// host's System Settings. It starts like a fresh Mac: ⇧⌘3, ⇧⌘4, and ⇧⌘5 belong to macOS.
        let systemShortcuts = E2ESystemShortcuts()

        init(output: E2EOutput) throws {
            self.output = output
            // Shortcut assignments live in UserDefaults (KeyboardShortcuts). The runner uses only its
            // own domain, cleared first, never the app's.
            guard let domain = Bundle.main.bundleIdentifier, domain == E2ESystemShortcuts.runnerDomain else {
                throw E2EAbort("the E2E runner must run as \(E2ESystemShortcuts.runnerDomain)")
            }
            UserDefaults.standard.removePersistentDomain(forName: domain)
            let work = output.workDirectory
            let dropFolder = work.appending(path: "drops", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dropFolder, withIntermediateDirectories: true)

            settings = SettingsStore.e2eInMemory()
            desktop = try SyntheticDesktop.image()
            capture = SyntheticCaptureService(desktop: desktop)
            permission = SyntheticScreenPermission()
            scrollFrames = SyntheticScrollFrames()
            let run = UUID().uuidString
            clipboard = PrivatePasteboardClipboard(
                pasteboard: NSPasteboard(name: NSPasteboard.Name("dev.mvneves.Recortia.E2E.image.\(run)")))
            textPasteboard = NSPasteboard(name: NSPasteboard.Name("dev.mvneves.Recortia.E2E.text.\(run)"))
            drag = SyntheticDragReceiver(dropFolder: dropFolder)

            let live = AppServices.live()
            exportGate = SyntheticExportGate(exporter: live.exporter)
            importInput = SyntheticImportInput(input: live.input)
            services = AppServices(
                githubUpload: github, githubCredentials: github,
                capture: capture, screenPermission: permission, accessibility: live.accessibility,
                assets: live.assets, input: importInput, renderer: live.renderer, exporter: exportGate,
                clipboard: clipboard, files: live.files, drag: drag, folders: live.folders,
                textRecognition: live.textRecognition, qrDecoder: live.qrDecoder, scrollFrames: scrollFrames,
                stitcher: live.stitcher, autoScroller: live.autoScroller, loginItem: live.loginItem, clock: live.clock)
            let system = systemShortcuts
            let messages = self.messages
            app = AppModel(
                settings: settings, services: services,
                shortcutRegistry: KeyboardShortcutsRegistry(
                    takenBySystem: { system.enabled.contains($0) }, probe: { _ in true }),
                showMessage: { messages.values.append($0) })
            guard let features = app.features else { throw E2EAbort("AppModel built no feature models") }
            self.features = features
            environment = EditorEnvironment(
                renderer: services.renderer, export: features.export, folders: services.folders,
                textRecognition: services.textRecognition, qrDecoder: services.qrDecoder, assets: services.assets,
                input: services.input, pins: features.pins,
                textClipboard: PasteboardTextClipboard(pasteboard: textPasteboard), links: links, settings: settings,
                imageImporter: features.importer.imageImporter)
            editors = E2EEditorHost(environment: environment)
            wire()
            // What a normal launch does (ADR-005), without registering any handler.
            ShortcutDefaults.seedIfNeeded(isNewInstall: !settings.preferences.hasCompletedOnboarding)
            app.shortcutStatus.refreshAll()
        }

        /// Mirrors `AppModel.wire`: every new document opens an editor.
        private func wire() {
            let editors = self.editors
            features.capture.onCaptured = { [weak app] completion in
                app?.handleCapture(completion)
            }
            features.importer.onImported = { editors.open($0) }
            features.scroll.onAccepted = { editors.open($0) }
            app.openDocument = { editors.open($0).model }
            app.recognizeText = { editors.open($0, initialAction: .recognizeText) }
        }

        /// Imports `image` as PNG through the real input, decode, and asset path; opens an editor.
        func openImported(_ image: CGImage, name: String) async throws -> EditorWindowController {
            let url = output.workDirectory.appending(path: name)
            try E2EDrawing.png(image).write(to: url, options: .atomic)
            let before = editors.controllers.count
            let result = await features.importer.importImage(from: .file(url))
            if case .failure(let failure) = result { throw E2EAbort("import of \(name) failed: \(failure)") }
            guard editors.controllers.count == before + 1, let controller = editors.controllers.last else {
                throw E2EAbort("import of \(name) opened no editor")
            }
            try await editors.waitForBase(controller.model)
            return controller
        }

        /// Closes editors and pins and resets per-scenario state.
        func reset() {
            exportGate.release()
            settings.update {
                $0.autoCopy = false; $0.autoSave = false; $0.githubUpload = nil
            }
            editors.closeAll()
            features.pins.closeAll()
            if features.capture.state.isActive { features.capture.cancel() }
            if features.scroll.state.isActive { features.scroll.cancel() }
        }

        func tearDown() {
            reset()
            clipboard.pasteboard.releaseGlobally()
            textPasteboard.releaseGlobally()
        }
    }

    @MainActor
    final class RecordingMessagePresenter {
        var values: [UserMessage] = []
    }

    /// `EditorWindowManager.open` without `present()`: real editor windows and models, parked
    /// offscreen at one fixed content size.
    @MainActor
    final class E2EEditorHost {
        private let environment: EditorEnvironment
        private(set) var controllers: [EditorWindowController] = []

        init(environment: EditorEnvironment) {
            self.environment = environment
        }

        @discardableResult
        func open(_ session: DocumentSession, initialAction: EditorInitialAction = .none) -> EditorWindowController {
            let model = EditorModel(session: session, environment: environment)
            let controller = EditorWindowController(model: model)
            if let window = controller.window {
                window.setContentSize(E2ESnapshot.editorSize)
                E2ESnapshot.park(window)
                window.contentView?.layoutSubtreeIfNeeded()
            }
            controllers.append(controller)
            if initialAction == .recognizeText {
                Task { await model.recognizeText() }
            }
            return controller
        }

        func closeAll() {
            for controller in controllers { controller.window?.close() }
            controllers.removeAll()
        }

        /// Waits until the sanitized base render matches the current document.
        func waitForBase(_ model: EditorModel, timeout: Duration = .seconds(15)) async throws {
            guard await E2EWait.until(timeout: timeout, { model.isBaseCurrent }) else {
                throw E2EAbort("the editor's base render did not finish within \(timeout)")
            }
        }
    }

    enum E2EWait {
        /// Polls `condition` on the main actor until it holds or `timeout` passes.
        @MainActor
        static func until(
            timeout: Duration = .seconds(10), poll: Duration = .milliseconds(20), _ condition: () -> Bool
        ) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while !condition() {
                if ContinuousClock.now >= deadline { return false }
                try? await Task.sleep(for: poll)
            }
            return true
        }
    }

    extension EditorWindowController {
        /// The window's content view (toolbar, sidebar, canvas, inspector, status bar).
        var contentRoot: NSView? { window?.contentView }

        /// The AppKit canvas, found in the hosted view hierarchy.
        var canvasView: EditorCanvasView? { contentRoot.flatMap { Self.first(EditorCanvasView.self, in: $0) } }

        static func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews {
                if let match = first(type, in: subview) { return match }
            }
            return nil
        }

        static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            var found: [T] = []
            if let match = view as? T { found.append(match) }
            for subview in view.subviews { found += all(type, in: subview) }
            return found
        }
    }

    /// A mutable stand-in for the enabled macOS shortcuts (`CopySymbolicHotKeys`).
    @MainActor
    final class E2ESystemShortcuts {
        static let runnerDomain = "dev.mvneves.Recortia.E2E"
        static let screenshotDefaults: Set<KeyboardShortcuts.Shortcut> = [
            .init(.three, modifiers: [.command, .shift]), .init(.four, modifiers: [.command, .shift]),
            .init(.five, modifiers: [.command, .shift]),
        ]
        var enabled = screenshotDefaults
    }
#endif
