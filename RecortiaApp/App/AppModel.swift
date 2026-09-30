import AppKit
import Domain
import Features
import KeyboardShortcuts
import Observation
import UniformTypeIdentifiers

/// Feature models that exist only when the live services are wired.
struct FeatureModels {
    let services: AppServices
    let capture: CaptureCoordinator
    let export: ExportCoordinator
    let importer: ImportCoordinator
    let scroll: ScrollSessionModel
    let pins: PinsModel
    let ocrLanguages: OCRLanguagesModel
    let loginItem: LoginItemModel

    init(services: AppServices, settings: SettingsStore) {
        self.services = services
        capture = CaptureCoordinator(
            capture: services.capture, permission: services.screenPermission, assets: services.assets,
            clock: services.clock, settings: settings)
        export = ExportCoordinator(
            exporter: services.exporter, clipboard: services.clipboard, files: services.files, drag: services.drag,
            folders: services.folders, clock: services.clock, settings: settings)
        importer = ImportCoordinator(input: services.input, assets: services.assets)
        scroll = ScrollSessionModel(
            frames: services.scrollFrames, stitcher: services.stitcher, autoScroller: services.autoScroller,
            accessibility: services.accessibility, screenPermission: services.screenPermission,
            assets: services.assets, clock: services.clock, settings: settings)
        pins = PinsModel(renderer: services.renderer, settings: settings)
        ocrLanguages = OCRLanguagesModel(service: services.textRecognition)
        loginItem = LoginItemModel(service: services.loginItem)
    }
}

/// The composition root's shell model: owns settings, onboarding, the feature models, and the
/// AppKit presenters, and implements `AppActions` for the menu and global shortcuts.
///
/// Integration points left for the editor and OCR owners:
/// - `openDocument` receives every new document (capture, import, paste, drop, scroll).
/// - `recognizeText` receives Capture Text results.
/// Commands that depend on an unset hook or on missing services are disabled.
@MainActor
@Observable
final class AppModel: AppActions {
    let settings: SettingsStore
    let onboarding: OnboardingModel
    let shortcutStatus: ShortcutStatusModel
    let features: FeatureModels?
    private var isStartingScrollingCapture = false

    var openDocument: ((DocumentSession) -> EditorModel?)?
    var recognizeText: ((DocumentSession) -> Void)?
    /// Installed by the menu from SwiftUI's `openSettings` environment action.
    @ObservationIgnored var openSettingsWindow: (() -> Void)?

    @ObservationIgnored private var captureUI: CaptureUIController?
    @ObservationIgnored private var scrollUI: ScrollUIController?
    @ObservationIgnored private var pinsUI: PinsUIController?
    @ObservationIgnored private var captureWindowVisibility: CaptureWindowVisibility?
    @ObservationIgnored private let onboardingWindow = OnboardingWindowController()
    @ObservationIgnored private let editors = EditorWindowManager()
    @ObservationIgnored private var systemEvents: SystemEventMonitor?
    @ObservationIgnored private var didLaunch = false
    @ObservationIgnored private lazy var captureMenu = CaptureMenuPresenter(actions: self)
    /// Re-checks held shortcuts until macOS lets their keys go (ADR-005).
    @ObservationIgnored private var heldShortcutWatch: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let showMessage: @MainActor @Sendable (UserMessage) -> Void

    init(
        settings: SettingsStore, services: AppServices?, shortcutRegistry: any ShortcutRegistry,
        showMessage: @escaping @MainActor @Sendable (UserMessage) -> Void = { MessagePresenter.present($0) }
    ) {
        self.settings = settings
        self.showMessage = showMessage
        onboarding = OnboardingModel(settings: settings)
        shortcutStatus = ShortcutStatusModel(registry: shortcutRegistry, names: ShortcutBinding.names)
        features = services.map { FeatureModels(services: $0, settings: settings) }
        captureWindowVisibility = features.map {
            CaptureWindowVisibility(capture: $0.capture, scroll: $0.scroll) { [weak self] in
                self?.isStartingScrollingCapture == true
            }
        }
        // Every path that holds a shortcut starts the watch, including a recording in Settings.
        shortcutStatus.onHold = { [weak self] in self?.watchHeldShortcuts() }
    }

    /// Called once from `applicationDidFinishLaunching`. Requests no permission.
    func launch() {
        guard !didLaunch else { return }
        didLaunch = true
        if let features {
            wire(features)
        }
        registerShortcutHandlers()
        if onboarding.shouldPresent {
            showOnboarding()
        }
    }

    func showOnboarding() {
        onboardingWindow.show(onboarding: onboarding, shortcutStatus: shortcutStatus)
    }

    // MARK: AppActions

    func isEnabled(_ command: AppCommand) -> Bool {
        if AppCommand.captureModes.contains(command), isStartingScrollingCapture { return false }
        switch command {
        case .captureRegion, .captureDisplay, .captureWindow, .captureWithDelay:
            return features != nil && openDocument != nil && features?.scroll.state.isActive == false
        case .scrollingCapture:
            return features != nil && openDocument != nil && features?.capture.state.isActive == false
        case .openImage, .pasteImage:
            return features != nil && openDocument != nil
        case .repeatLastRegion:
            return features?.capture.hasRepeatRegion == true && openDocument != nil
                && features?.scroll.state.isActive == false
        case .captureText:
            return features != nil && recognizeText != nil && features?.scroll.state.isActive == false
        case .captureMenu:
            return AppCommand.captureModes.contains { isEnabled($0) }
        case .bringPinsForward, .closeAllPins:
            return features?.pins.pins.isEmpty == false
        case .settings, .about, .quit:
            return true
        }
    }

    func perform(_ command: AppCommand) {
        guard isEnabled(command) else { return }
        if AppCommand.captureModes.contains(command) {
            captureWindowVisibility?.suspend()
        }
        switch command {
        case .captureRegion: features?.capture.start(.region)
        case .captureDisplay: features?.capture.start(.display)
        case .captureWindow: features?.capture.start(.window)
        case .captureWithDelay:
            if let capture = features?.capture {
                capture.start(.region, delaySeconds: capture.delayForDelayedCapture)
            }
        case .repeatLastRegion: features?.capture.start(.repeatRegion)
        case .scrollingCapture: startScrollingCapture()
        case .captureText: features?.capture.start(.region, purpose: .recognizeText)
        case .captureMenu: captureMenu.present()
        case .openImage: chooseImageFile()
        case .pasteImage: importImage(from: .pasteboard)
        case .bringPinsForward: features?.pins.bringForward()
        case .closeAllPins: features?.pins.closeAll()
        case .settings: showSettings()
        case .about:
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        case .quit: NSApp.terminate(nil)
        }
    }

    func showSettings() {
        NSApp.activate()
        openSettingsWindow?()
    }

    /// Imports a dropped or opened file; used by Open Image and by drop targets.
    func importImage(from source: ImportSource) {
        guard let importer = features?.importer else { return }
        Task {
            if case .failure(let failure) = await importer.importImage(from: source) {
                showMessage(.importFailure(failure))
            }
        }
    }

    // MARK: Wiring

    private func wire(_ features: FeatureModels) {
        features.capture.onCaptured = { [weak self] completion in
            self?.handleCapture(completion)
        }
        features.importer.onImported = { [weak self] session in
            _ = self?.openDocument?(session)
        }
        features.scroll.onAccepted = { [weak self] session in
            _ = self?.openDocument?(session)
        }
        captureUI = CaptureUIController(coordinator: features.capture)
        scrollUI = ScrollUIController(model: features.scroll, displays: { features.services.capture.displays() })
        pinsUI = PinsUIController(model: features.pins)

        let services = features.services
        let environment = EditorEnvironment(
            renderer: services.renderer, export: features.export, folders: services.folders,
            textRecognition: services.textRecognition, qrDecoder: services.qrDecoder, assets: services.assets,
            input: services.input, pins: features.pins, textClipboard: PasteboardTextClipboard(),
            links: WorkspaceLinkOpener(), settings: settings)
        openDocument = { [editors] session in editors.open(session, environment: environment) }
        let monitor = SystemEventMonitor { event in
            switch event {
            case .displaysChanged:
                features.capture.displayConfigurationChanged()
                features.scroll.interrupt(because: .displayChanged)
            case .screenLocked:
                features.capture.interrupt(because: .screenLocked)
                features.scroll.interrupt(because: .screenLocked)
            }
        }
        monitor.start()
        systemEvents = monitor
        recognizeText = { [editors] session in
            editors.open(session, environment: environment, initialAction: .recognizeText)
        }
    }

    private func handleCapture(_ completion: CaptureCompletion) {
        switch completion.purpose {
        case .edit:
            let editor = openDocument?(completion.session)
            runAutomaticExports(for: completion.session, editor: editor)
        case .recognizeText:
            recognizeText?(completion.session)
        }
    }

    /// Auto-copy/auto-save run on the fresh capture, before any later edit, and only when enabled.
    /// Freshness is checked against the editor's live session: an edit or redaction made while the
    /// export renders, or closing the editor, makes it stale, so the unedited capture is not sent.
    private func runAutomaticExports(for session: DocumentSession, editor: EditorModel?) {
        guard let export = features?.export else { return }
        let preferences = settings.preferences
        guard preferences.autoCopy || preferences.autoSave else { return }
        let opened = editor != nil
        let live: () -> DocumentSession? = { [weak editor] in
            // No editor wired: the capture itself is current. An editor that closed (or was
            // released) makes the export stale.
            guard opened else { return session }
            guard let editor, !editor.isClosed else { return nil }
            return editor.session
        }
        Task {
            let outcomes = await export.runAutomaticExports(for: session, currentSession: live)
            for case .failed(let failure) in outcomes {
                showMessage(.export(failure))
            }
        }
    }

    private func startScrollingCapture() {
        guard let scroll = features?.scroll else { return }
        isStartingScrollingCapture = true
        Task {
            // Permission denial can leave the scroll model idle without an observed transition.
            defer {
                isStartingScrollingCapture = false
                captureWindowVisibility?.restoreIfFinished()
            }
            if !(await scroll.begin()), scroll.notice == .screenPermissionDenied {
                showMessage(.capture(.permissionDenied))
            }
        }
    }

    private func toggleScrollingCapture() {
        guard let scroll = features?.scroll else { return }
        switch scroll.state {
        case .collecting, .paused: scroll.stop()
        case .armed: scroll.start()
        case .selecting: scroll.cancel()
        default: perform(.scrollingCapture)
        }
    }

    private func chooseImageFile() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a PNG or JPEG image to open.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importImage(from: .file(url))
    }

    private func registerShortcutHandlers() {
        // Hold what macOS claims before any handler exists, so KeyboardShortcuts never registers
        // those keys, even briefly.
        refreshShortcuts()
        for binding in ShortcutBinding.all {
            let name = binding.name
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
                // A press macOS also claims (its shortcut was turned back on) is left to macOS.
                guard let self else { return }
                guard self.shortcutStatus.admitPress(named: name.rawValue) else { return }
                if let command = binding.command {
                    self.perform(command)
                } else if name == .scrollingToggle {
                    self.toggleScrollingCapture()
                }
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshShortcuts() }
        }
    }

    /// Registers or holds every shortcut. Holding one starts a two-second watch (`onHold`), so a
    /// default starts working soon after the user turns the macOS shortcut off (ADR-005).
    func refreshShortcuts() {
        shortcutStatus.refreshAll()
        watchHeldShortcuts()
    }

    /// Restore Defaults in Settings: the macOS-style table, every other command cleared.
    func restoreDefaultShortcuts() {
        shortcutStatus.reassign { ShortcutDefaults.restore() }
    }

    private func watchHeldShortcuts() {
        guard shortcutStatus.isHoldingAny else {
            heldShortcutWatch?.cancel()
            heldShortcutWatch = nil
            return
        }
        guard heldShortcutWatch == nil else { return }
        heldShortcutWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.shortcutStatus.refreshHeld()
                if !self.shortcutStatus.isHoldingAny {
                    self.heldShortcutWatch = nil
                    return
                }
            }
        }
    }
}
