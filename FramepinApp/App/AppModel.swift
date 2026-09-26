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

    var openDocument: ((DocumentSession) -> Void)?
    var recognizeText: ((DocumentSession) -> Void)?
    /// Installed by the menu from SwiftUI's `openSettings` environment action.
    @ObservationIgnored var openSettingsWindow: (() -> Void)?

    @ObservationIgnored private var captureUI: CaptureUIController?
    @ObservationIgnored private var scrollUI: ScrollUIController?
    @ObservationIgnored private var pinsUI: PinsUIController?
    @ObservationIgnored private let onboardingWindow = OnboardingWindowController()
    @ObservationIgnored private var didLaunch = false

    init(settings: SettingsStore, services: AppServices?, shortcutProbe: any ShortcutRegistrationProbe) {
        self.settings = settings
        onboarding = OnboardingModel(settings: settings)
        shortcutStatus = ShortcutStatusModel(probe: shortcutProbe)
        features = services.map { FeatureModels(services: $0, settings: settings) }
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
        switch command {
        case .captureRegion, .captureDisplay, .captureWindow, .captureWithDelay, .scrollingCapture, .openImage,
            .pasteImage:
            return features != nil && openDocument != nil
        case .repeatLastRegion:
            return features?.capture.hasRepeatRegion == true && openDocument != nil
        case .captureText:
            return features != nil && recognizeText != nil
        case .bringPinsForward, .closeAllPins:
            return features?.pins.pins.isEmpty == false
        case .settings, .about, .quit:
            return true
        }
    }

    func perform(_ command: AppCommand) {
        guard isEnabled(command) else { return }
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
                MessagePresenter.present(.importFailure(failure))
            }
        }
    }

    // MARK: Wiring

    private func wire(_ features: FeatureModels) {
        features.capture.onCaptured = { [weak self] completion in
            self?.handleCapture(completion)
        }
        features.importer.onImported = { [weak self] session in
            self?.openDocument?(session)
        }
        features.scroll.onAccepted = { [weak self] session in
            self?.openDocument?(session)
        }
        captureUI = CaptureUIController(coordinator: features.capture)
        scrollUI = ScrollUIController(model: features.scroll, displays: { features.services.capture.displays() })
        pinsUI = PinsUIController(model: features.pins)
    }

    private func handleCapture(_ completion: CaptureCompletion) {
        switch completion.purpose {
        case .edit:
            openDocument?(completion.session)
            runAutomaticExports(for: completion.session)
        case .recognizeText:
            recognizeText?(completion.session)
        }
    }

    /// Auto-copy/auto-save run on the fresh capture, before any later edit, and only when enabled.
    private func runAutomaticExports(for session: DocumentSession) {
        guard let export = features?.export else { return }
        let preferences = settings.preferences
        guard preferences.autoCopy || preferences.autoSave else { return }
        Task {
            let outcomes = await export.runAutomaticExports(for: session, currentSession: { session })
            for case .failed(let failure) in outcomes {
                MessagePresenter.present(.export(failure))
            }
        }
    }

    private func startScrollingCapture() {
        guard let scroll = features?.scroll else { return }
        Task {
            if !(await scroll.begin()), scroll.notice == .screenPermissionDenied {
                MessagePresenter.present(.capture(.permissionDenied))
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
        for binding in ShortcutBinding.all {
            let name = binding.name
            if let command = binding.command {
                KeyboardShortcuts.onKeyUp(for: name) { [weak self] in self?.perform(command) }
            } else if name == .scrollingToggle {
                KeyboardShortcuts.onKeyUp(for: name) { [weak self] in self?.toggleScrollingCapture() }
            }
            shortcutStatus.shortcutChanged(
                named: name.rawValue, isAssigned: KeyboardShortcuts.getShortcut(for: name) != nil)
        }
    }
}
