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
        let accessibility = SyntheticAccessibilityPermission()
        let scrollFrames: SyntheticScrollFrames
        /// Records automatic-scroll steps; never posts a system event to this Mac.
        let autoScroll = SyntheticAutoScroll()
        let clipboard: PrivatePasteboardClipboard
        let textPasteboard: NSPasteboard
        let drag: SyntheticDragReceiver
        let github = SyntheticGitHubUpload()
        let exportGate: SyntheticExportGate
        let importInput: SyntheticImportInput
        let links = RecordingLinkOpener()
        /// Scripted detection for automatic masking; never reads the screen or runs Vision.
        let sensitiveText: SyntheticSensitiveText
        let messages = RecordingMessagePresenter()
        let quit = RecordingQuitConfirmation()
        /// Termination requests from quit-after-last-window; the runner process itself never quits.
        let terminations = RecordingTerminations()
        /// Stands in for the save-folder panel; never shows one.
        let folderChooser = ScriptedFolderChooser()
        let services: AppServices
        let app: AppModel
        let features: FeatureModels
        let editors: E2EEditorHost
        let environment: EditorEnvironment
        /// The product's thumbnail controller; its panel is parked offscreen and Save never shows a panel.
        let quickActionsUI: QuickActionsUIController
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
            sensitiveText = SyntheticSensitiveText(clock: E2EClock())

            let live = AppServices.live(settings: settings)
            exportGate = SyntheticExportGate(exporter: live.exporter)
            importInput = SyntheticImportInput(input: live.input)
            services = AppServices(
                githubUpload: github, githubCredentials: github,
                capture: capture, screenPermission: permission, accessibility: accessibility,
                assets: live.assets, input: importInput, renderer: live.renderer, exporter: exportGate,
                clipboard: clipboard, files: live.files, drag: drag, folders: live.folders,
                textRecognition: live.textRecognition, qrDecoder: live.qrDecoder, sensitiveText: sensitiveText,
                scrollFrames: scrollFrames,
                stitcher: live.stitcher, autoScroller: autoScroll, loginItem: live.loginItem, clock: sensitiveText.clock
            )
            let system = systemShortcuts
            let messages = self.messages
            app = AppModel(
                settings: settings, services: services,
                shortcutRegistry: KeyboardShortcutsRegistry(
                    takenBySystem: { system.enabled.contains($0) }, probe: { _ in true }),
                showMessage: { messages.present($0, on: $1) },
                confirmQuit: { [quit] in quit.answer($0) },
                requestTermination: { [terminations] in terminations.request() },
                chooseSaveFolder: { [folderChooser] in folderChooser.next() },
                textClipboard: PasteboardTextClipboard(pasteboard: textPasteboard))
            let features = app.features
            self.features = features
            environment = EditorEnvironment(
                renderer: services.renderer, export: features.export, folders: services.folders,
                textRecognition: services.textRecognition, qrDecoder: services.qrDecoder,
                sensitiveText: services.sensitiveText, assets: services.assets, input: services.input,
                pins: features.pins, textClipboard: features.textClipboard, links: links,
                settings: settings, clock: services.clock, imageImporter: features.importer.imageImporter)
            editors = E2EEditorHost(environment: environment)
            quickActionsUI = QuickActionsUIController(model: features.quickActions, settings: settings)
            quickActionsUI.present = { panel in
                panel.sizeToContentIfUnsized()
                E2ESnapshot.park(panel)
                panel.orderFrontRegardless()
            }
            quickActionsUI.chooseSaveDestination = { nil }
            quickActionsUI.confirmReplacement = { _ in false }
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
            features.importer.onImported = {
                editors.open($0, importedFileName: $1, initialAction: $2 ? .maskSensitiveText : .none)
            }
            features.scroll.onAccepted = { editors.open($0, initialAction: $1 ? .maskSensitiveText : .none) }
            app.openDocument = { editors.open($0, importedFileName: $2, initialAction: $1).model }
            app.recognizeText = { editors.open($0, initialAction: .recognizeText) }
            features.quickActions.onOpenInEditor = { editors.open($0) }
            app.unexportedEditCount = { editors.unexportedEditCount }
            app.editorWindow = { model in editors.controllers.first { $0.model === model }?.window }
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

        func reset() {
            exportGate.release()
            sensitiveText.reset()
            settings.update {
                $0.autoCopy = false; $0.autoSave = false; $0.githubUpload = nil
                $0.keepsRunningInMenuBar = true; $0.autoRedactsSensitiveText = false
                $0.afterCapture = .openEditor
            }
            features.quickActions.dismiss()
            folderChooser.answers = []
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

    /// Stands in for `MessagePresenter.present(_:on:)`. An app alert is only recorded, never shown,
    /// so no modal loop runs. A sheet is recorded with its parent and attached for real, without a
    /// modal loop, so a scenario sees it on that window and answers it with `endSheet`; a sheet the
    /// window's close ends is recorded again as the app alert it becomes. Never opens System Settings.
    @MainActor
    final class RecordingMessagePresenter {
        struct Request {
            let message: UserMessage
            let isSheet: Bool
            /// The editor window the sheet was attached to.
            weak var sheetParent: NSWindow?
        }

        private(set) var requests: [Request] = []
        /// Every message, alert or sheet, in the order it was asked for.
        var values: [UserMessage] { requests.map(\.message) }
        var alerts: [UserMessage] { requests.filter { !$0.isSheet }.map(\.message) }

        func present(_ message: UserMessage, on target: MessageTarget) {
            switch target {
            case .app:
                requests.append(Request(message: message, isSheet: false))
            case .sheet(let window):
                requests.append(Request(message: message, isSheet: true, sheetParent: window))
                MessagePresenter.beginSheet(message, on: window) { [weak self] in self?.present($0, on: .app) }
            }
        }
    }

    /// Stands in for the Quit confirmation alert: records each question and answers from a script
    /// (declining when the script is empty). No modal alert is shown.
    @MainActor
    final class RecordingQuitConfirmation {
        var answers: [Bool] = []
        var questions: [QuitDiscards] = []

        func answer(_ discards: QuitDiscards) -> Bool {
            questions.append(discards)
            return answers.isEmpty ? false : answers.removeFirst()
        }
    }

    @MainActor
    final class RecordingTerminations {
        private(set) var count = 0
        /// Runs at each request, so a scenario can record what was true at that moment.
        var onRequest: (() -> Void)?

        func request() {
            count += 1
            onRequest?()
        }
    }

    /// Answers the save-folder panel from a script: each answer is a folder, or nil for Cancel
    /// (also when the script is empty). Records how often it was asked.
    @MainActor
    final class ScriptedFolderChooser {
        var answers: [URL?] = []
        private(set) var asked = 0

        func next() -> URL? {
            asked += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    /// `EditorWindowManager.open` without `present()`: real editor windows and models, parked
    /// offscreen at one fixed content size.
    @MainActor
    final class E2EEditorHost {
        private let environment: EditorEnvironment
        private(set) var controllers: [EditorWindowController] = []
        /// Applied to editors opened from now on; scenarios record announcements through it.
        var noticePresentation = EditorNoticePresentation()

        init(environment: EditorEnvironment) {
            self.environment = environment
        }

        @discardableResult
        func open(
            _ session: DocumentSession, importedFileName: String? = nil, initialAction: EditorInitialAction = .none
        ) -> EditorWindowController {
            let model = EditorModel(
                session: session, environment: environment, autoRedacts: initialAction == .maskSensitiveText)
            let controller = EditorWindowController(
                model: model, importedFileName: importedFileName, noticePresentation: noticePresentation)
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

        var unexportedEditCount: Int { controllers.filter { $0.hasUnexportedEdits() }.count }

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
        /// The window's content view: the split view holding the object list, the canvas column
        /// (canvas and status bar) and the inspector; the tools are in its toolbar.
        var contentRoot: NSView? { window?.contentView }

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
