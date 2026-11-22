import AppKit
import Domain
import Features
import KeyboardShortcuts
import Observation
import UniformTypeIdentifiers

struct FeatureModels {
    let services: AppServices
    let capture: CaptureCoordinator
    let export: ExportCoordinator
    let importer: ImportCoordinator
    let scroll: ScrollSessionModel
    let pins: PinsModel
    let quickActions: QuickActionsModel
    let ocrLanguages: OCRLanguagesModel
    let loginItem: LoginItemModel
    /// Check for Updates… and its Settings toggle (FP-024).
    let updater: UpdaterModel
    /// Reopen Closed Capture: filled only by closing an editor window.
    let closedCapture: ClosedCaptureSlot
    /// Nil only without a diagnostics log (previews).
    let diagnostics: DiagnosticsRecorder?

    /// The plain-text clipboard for explicit Copy actions on text (recognized text, an upload link).
    let textClipboard: any TextClipboardService

    init(services: AppServices, settings: SettingsStore, textClipboard: any TextClipboardService) {
        self.services = services
        self.textClipboard = textClipboard
        let diagnostics = services.diagnosticsLog.map {
            DiagnosticsRecorder(log: $0, settings: settings, clock: services.clock, versions: .current)
        }
        self.diagnostics = diagnostics
        capture = CaptureCoordinator(
            capture: services.capture, permission: services.screenPermission, assets: services.assets,
            clock: services.clock, settings: settings, sound: services.captureSound,
            elements: services.interfaceElements, diagnostics: diagnostics)
        export = ExportCoordinator(
            exporter: services.exporter, clipboard: services.clipboard, files: services.files, drag: services.drag,
            printer: services.printer, folders: services.folders, clock: services.clock, settings: settings,
            upload: services.githubUpload, diagnostics: diagnostics)
        importer = ImportCoordinator(input: services.input, assets: services.assets, settings: settings)
        scroll = ScrollSessionModel(
            frames: services.scrollFrames, stitcher: services.stitcher, autoScroller: services.autoScroller,
            accessibility: services.accessibility, screenPermission: services.screenPermission,
            assets: services.assets, clock: services.clock, settings: settings, diagnostics: diagnostics)
        pins = PinsModel(renderer: services.renderer, settings: settings, export: export)
        quickActions = QuickActionsModel(
            export: export, pins: pins, renderer: services.renderer, assets: services.assets,
            folders: services.folders, settings: settings, clock: services.clock, textClipboard: textClipboard)
        ocrLanguages = OCRLanguagesModel(service: services.textRecognition)
        loginItem = LoginItemModel(service: services.loginItem)
        updater = UpdaterModel(service: services.updates, settings: settings)
        closedCapture = ClosedCaptureSlot(assets: services.assets, clock: services.clock)
    }
}

/// The composition root's shell model: owns settings, onboarding, the feature models, and the
/// AppKit presenters, and implements `AppActions` for the menu and global shortcuts.
///
/// `openDocument` receives every new document (capture, import, paste, drop, scroll) and
/// `recognizeText` receives Capture Text results. Commands that depend on an unset hook are
/// disabled.
@MainActor
@Observable
final class AppModel: AppActions {
    let settings: SettingsStore
    let onboarding: OnboardingModel
    let shortcutStatus: ShortcutStatusModel
    let features: FeatureModels
    /// Window › Unlock All Pins in the app's menu bar.
    @ObservationIgnored let pinMenu: PinMenuState
    /// File › Reopen Closed Capture in the app's menu bar.
    @ObservationIgnored let reopenMenu: ReopenMenuState
    private var isStartingScrollingCapture = false

    var openDocument: ((DocumentSession, EditorInitialAction, _ importedFileName: String?) -> EditorModel?)?
    var recognizeText: ((DocumentSession) -> Void)?
    @ObservationIgnored private lazy var settingsWindow = SettingsWindowController(model: self)

    @ObservationIgnored private var captureUI: CaptureUIController?
    @ObservationIgnored private var scrollUI: ScrollUIController?
    @ObservationIgnored private var pinsUI: PinsUIController?
    @ObservationIgnored private var quickActionsUI: QuickActionsUIController?
    @ObservationIgnored private var captureWindowVisibility: CaptureWindowVisibility?
    @ObservationIgnored private let onboardingWindow = OnboardingWindowController()
    /// Open requests the system made before launch wired the editors, each kept apart: a cold
    /// launch by Open With, a drop on the Dock icon or `open -a` delivers them before
    /// `applicationDidFinishLaunching`.
    @ObservationIgnored private var requestsBeforeLaunch: [[URL]] = []
    @ObservationIgnored private let editors = EditorWindowManager()
    @ObservationIgnored private var systemEvents: SystemEventMonitor?
    @ObservationIgnored private var didLaunch = false
    @ObservationIgnored private lazy var captureMenu = CaptureMenuPresenter(actions: self)
    /// Re-checks held shortcuts until macOS lets their keys go (ADR-005).
    @ObservationIgnored private var heldShortcutWatch: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?
    /// Adopts framework-made windows (About, alerts) that lack a Space policy before the app
    /// activates, so activation cannot switch Spaces (FR-01).
    @ObservationIgnored private let spacePolicy = SpacePolicyMonitor()
    @ObservationIgnored private let showMessage: @MainActor @Sendable (UserMessage, MessageTarget) -> Void
    /// The window of an open editor, for messages shown as a sheet on it.
    @ObservationIgnored var editorWindow: (EditorModel) -> NSWindow? = { _ in nil }
    /// Open editors whose edits were never copied or saved (a drag out saves; a pin does not).
    @ObservationIgnored var unexportedEditCount: () -> Int = { 0 }
    /// Asks whether to quit and discard what `QuitDiscards` describes.
    @ObservationIgnored private let confirmQuit: @MainActor (QuitDiscards) -> Bool
    /// Asks whether to open the updater's window for an update a check found.
    @ObservationIgnored private let confirmUpdate: @MainActor (UserMessage) -> Bool
    /// Normal termination (`applicationShouldTerminate` still confirms unexported edits).
    @ObservationIgnored private let requestTermination: @MainActor () -> Void
    /// Asks the person for the automatic-save folder; nil when they cancel.
    @ObservationIgnored let chooseSaveFolder: @MainActor () -> URL?
    /// Automatic exports from scheduling until their results were reported.
    private var automaticExportsInFlight = 0
    /// Open With requests from their start until their refusals were reported.
    private var openRequestsInFlight = 0
    /// Identifies the current quit-after-last-window decision; a newer close, accepted capture
    /// or final answer makes earlier pending re-evaluations do nothing.
    @ObservationIgnored private var quitDecision = 0

    init(
        settings: SettingsStore, services: AppServices, shortcutRegistry: any ShortcutRegistry,
        showMessage: @escaping @MainActor @Sendable (UserMessage, MessageTarget) -> Void = {
            MessagePresenter.present($0, on: $1)
        },
        confirmQuit: @escaping @MainActor (QuitDiscards) -> Bool = { MessagePresenter.confirmDiscardOnQuit($0) },
        confirmUpdate: @escaping @MainActor (UserMessage) -> Bool = { MessagePresenter.confirmUpdate($0) },
        requestTermination: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
        chooseSaveFolder: @escaping @MainActor () -> URL? = { SaveFolderPanel.choose() },
        textClipboard: any TextClipboardService = PasteboardTextClipboard()
    ) {
        self.settings = settings
        self.showMessage = showMessage
        self.confirmQuit = confirmQuit
        self.confirmUpdate = confirmUpdate
        self.requestTermination = requestTermination
        self.chooseSaveFolder = chooseSaveFolder
        onboarding = OnboardingModel(settings: settings)
        shortcutStatus = ShortcutStatusModel(registry: shortcutRegistry, names: ShortcutBinding.names)
        features = FeatureModels(services: services, settings: settings, textClipboard: textClipboard)
        pinMenu = PinMenuState(pins: features.pins)
        reopenMenu = ReopenMenuState(slot: features.closedCapture)
        captureWindowVisibility = CaptureWindowVisibility(capture: features.capture, scroll: features.scroll) {
            [weak self] in self?.isStartingScrollingCapture == true
        }
        spacePolicy.start()
        AppPresence.shared.start()
        // Every path that holds a shortcut starts the watch, including a recording in Settings.
        shortcutStatus.onHold = { [weak self] in self?.watchHeldShortcuts() }
        shortcutStatus.onAttention = { [weak self] in self?.watchHeldShortcuts(restart: true) }
        AppPresence.shared.onLastWindowClosed = { [weak self] in self?.lastWindowClosed() }
    }

    /// Called once from `applicationDidFinishLaunching`. Requests no permission. Opening Recortia
    /// shows onboarding or Settings, so it appears in ⌘Tab and the Dock; Open at login stays silent
    /// once onboarding is complete.
    func launch(kind: LaunchKind) {
        guard !didLaunch else { return }
        didLaunch = true
        features.diagnostics?.recordLaunch()
        features.updater.start()
        wire(features)
        registerShortcutHandlers()
        switch LaunchWindow.choose(
            onboardingPending: onboarding.shouldPresent, kind: kind, opensFiles: !requestsBeforeLaunch.isEmpty)
        {
        case .onboarding: showOnboarding()
        case .settings: showSettings()
        case .none: break
        }
        openFilesRequestedBeforeLaunch()
    }

    func showOnboarding() {
        onboardingWindow.show(onboarding: onboarding, shortcutStatus: shortcutStatus)
    }

    // MARK: AppActions

    func isEnabled(_ command: AppCommand) -> Bool {
        if AppCommand.captureModes.contains(command), isStartingScrollingCapture { return false }
        switch command {
        case .captureRegion, .captureDisplay, .captureWindow, .captureWithDelay:
            return openDocument != nil && !features.scroll.state.isActive
        case .scrollingCapture:
            return openDocument != nil && !features.capture.state.isActive
        case .openImage, .pasteImage:
            return openDocument != nil && !features.importer.isImporting
        case .reopenClosedCapture:
            return openDocument != nil && !features.closedCapture.isEmpty
        case .repeatLastRegion:
            return features.capture.hasRepeatRegion && openDocument != nil && !features.scroll.state.isActive
        case .captureText:
            return recognizeText != nil && !features.scroll.state.isActive
        case .captureMenu:
            return AppCommand.captureModes.contains { isEnabled($0) }
        case .bringPinsForward, .closeAllPins:
            return !features.pins.pins.isEmpty
        case .unlockAllPins:
            return features.pins.hasClickThroughPin
        case .checkForUpdates:
            return features.updater.canCheck
        case .settings, .featureTour, .about, .quit:
            return true
        }
    }

    func perform(_ command: AppCommand) {
        guard isEnabled(command) else { return }
        if AppCommand.captureModes.contains(command) {
            // A capture can start and cancel before an observation task re-evaluates the quit.
            quitDecision += 1
            captureWindowVisibility?.suspend()
        }
        switch command {
        case .captureRegion: features.capture.start(.region)
        case .captureDisplay: features.capture.start(.display)
        case .captureWindow: features.capture.start(.window)
        case .captureWithDelay: features.capture.start(.region, delaySeconds: features.capture.delayForDelayedCapture)
        case .repeatLastRegion: features.capture.start(.repeatRegion)
        case .scrollingCapture: startScrollingCapture()
        case .captureText: features.capture.start(.region, purpose: .recognizeText)
        case .captureMenu: captureMenu.present()
        case .openImage: chooseImageFile()
        case .pasteImage: importImage(from: .pasteboard)
        case .reopenClosedCapture:
            // A new editor through the normal open path; masking already settled before the close.
            if let session = features.closedCapture.take() { _ = openDocument?(session, .none, nil) }
        case .bringPinsForward: features.pins.bringForward()
        case .closeAllPins: features.pins.closeAll()
        case .unlockAllPins: features.pins.unlockAll()
        case .settings: showSettings()
        case .featureTour:
            if !onboardingWindow.isVisible { onboarding.beginTour() }
            showOnboarding()
        case .about:
            AppPresence.shared.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        case .checkForUpdates: Task { await checkForUpdates() }
        case .quit: NSApp.terminate(nil)
        }
    }

    /// Check for Updates… (FP-024): the only request a fresh install ever makes to the update feed.
    /// An update found opens the updater's own window only after the person agrees.
    func checkForUpdates() async {
        guard let result = await features.updater.check() else { return }
        switch result {
        case .noUpdate:
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            showMessage(.updateNotFound(version: version), .app)
        case .failed: showMessage(.updateCheckFailed, .app)
        case .updateAvailable(let version):
            if confirmUpdate(.updateAvailable(version: version)) { features.updater.install() }
        case .inProgress: break
        }
    }

    /// Whether the app may terminate now (`applicationShouldTerminate`). Termination never asks
    /// each editor's `windowShouldClose` or the scrolling review's, so unexported edits and a
    /// stitched capture still in review are confirmed here (FR-04, FR-10).
    func shouldTerminate() -> Bool {
        let discards = QuitDiscards(
            editedImages: unexportedEditCount(), scrollingReview: features.scroll.state == .reviewing)
        return discards.isEmpty || confirmQuit(discards)
    }

    /// `applicationWillTerminate`: the kept closed document never outlives the process's quit.
    func willTerminate() {
        features.closedCapture.clear()
    }

    /// The person closed Recortia's last window (FR-01). With "keep running in the menu bar" off
    /// this requests normal termination, after any export in progress has finished.
    private func lastWindowClosed() {
        quitDecision += 1
        decideQuit(quitDecision)
    }

    /// Decides now, or again whenever an input it read changes, until it quits or stays.
    private func decideQuit(_ decision: Int) {
        guard decision == quitDecision else { return }
        let outcome = withObservationTracking {
            QuitAfterLastWindow.decide(
                keepsRunningInMenuBar: settings.preferences.keepsRunningInMenuBar,
                isExporting: features.export.isBusy || automaticExportsInFlight > 0,
                isOpeningFiles: openRequestsInFlight > 0,
                hasUserWindow: AppPresence.shared.hasUserWindow,
                isCapturing: features.capture.state.isActive || features.scroll.state.isActive
                    || isStartingScrollingCapture)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.decideQuit(decision) }
        }
        switch outcome {
        case .wait: return
        case .stay: quitDecision += 1
        case .quit:
            quitDecision += 1
            requestTermination()
        }
    }

    func report(_ message: UserMessage) {
        showMessage(message, .app)
    }

    /// The General switch and removing the icon from the menu bar both come here; the first time
    /// the icon is hidden, the person is told how to get back. Presence and quitting do not change.
    func setShowsMenuBarIcon(_ shows: Bool) {
        if settings.setShowsMenuBarIcon(shows) { showMessage(.menuBarIconHidden, .app) }
    }

    func showSettings() {
        settingsWindow.show()
    }

    /// A Dock click or relaunch: restores a minimized window, else opens Settings so the app stays
    /// reachable (FR-01).
    func handleReopen(hasVisibleWindows: Bool) {
        guard !hasVisibleWindows else { return }
        if let window = AppPresence.shared.minimizedWindow {
            window.deminiaturize(nil)
        } else {
            showSettings()
        }
    }

    /// Imports a dropped or opened file; used by Open Image and by drop targets.
    func importImage(from source: ImportSource) {
        let importer = features.importer
        Task {
            if case .failure(let failure) = await importer.importImage(from: source) {
                showMessage(.importFailure(failure), .app)
            }
        }
    }

    /// Open With, a drop on the Dock icon and `open -a` (FR-03): one editor per file through the
    /// same admission as Open Image, and one report for every file that was refused.
    func openFiles(_ urls: [URL]) {
        guard openDocument != nil else {
            requestsBeforeLaunch.append(urls)
            return
        }
        _ = open([urls])
    }

    /// Replays, in order, the requests that arrived before the editors were wired.
    @discardableResult
    func openFilesRequestedBeforeLaunch() -> Task<Void, Never>? {
        let requests = requestsBeforeLaunch
        requestsBeforeLaunch = []
        guard !requests.isEmpty else { return nil }
        return open(requests)
    }

    private func open(_ requests: [[URL]]) -> Task<Void, Never> {
        let importer = features.importer
        // Counted until reported, so closing the first opened editor while the next file decodes
        // waits for the rest of the request instead of quitting.
        openRequestsInFlight += 1
        return Task {
            defer { openRequestsInFlight -= 1 }
            for failures in await importer.openRequests(requests) {
                if let message = UserMessage.openFailures(failures) { showMessage(message, .app) }
            }
        }
    }

    // MARK: Wiring

    private func wire(_ features: FeatureModels) {
        features.capture.onCaptured = { [weak self] completion in
            self?.handleCapture(completion)
        }
        // Scrolling captures and new documents from Open, Open With, a drop or Paste have no
        // automatic export batch; masking, when on, is decided as each document is created.
        features.importer.onImported = { [weak self] session, fileName, masks in
            _ = self?.openDocument?(session, masks ? .maskSensitiveText : .none, fileName)
        }
        features.scroll.onAccepted = { [weak self] session, masks in
            _ = self?.openDocument?(session, masks ? .maskSensitiveText : .none, nil)
        }
        captureUI = CaptureUIController(coordinator: features.capture)
        scrollUI = ScrollUIController(model: features.scroll, displays: { features.services.capture.displays() })
        pinsUI = PinsUIController(model: features.pins)
        quickActionsUI = QuickActionsUIController(model: features.quickActions, settings: settings)
        features.quickActions.onOpenInEditor = { [weak self] session in
            _ = self?.openDocument?(session, .none, nil)
        }

        let services = features.services
        let environment = EditorEnvironment(
            renderer: services.renderer, export: features.export, folders: services.folders,
            textRecognition: services.textRecognition, qrDecoder: services.qrDecoder,
            sensitiveText: services.sensitiveText, assets: services.assets, input: services.input,
            pins: features.pins, textClipboard: features.textClipboard, links: WorkspaceLinkOpener(),
            settings: settings, clock: services.clock, imageImporter: features.importer.imageImporter,
            diagnostics: features.diagnostics)
        openDocument = { [editors] session, action, fileName in
            editors.open(session, environment: environment, importedFileName: fileName, initialAction: action)
        }
        editors.closedCapture = features.closedCapture
        unexportedEditCount = { [editors] in editors.unexportedEditCount }
        editorWindow = { [editors] in editors.window(for: $0) }
        let monitor = SystemEventMonitor { [weak self] event in
            switch event {
            case .displaysChanged:
                features.capture.displayConfigurationChanged()
                features.scroll.interrupt(because: .displayChanged)
                self?.prepareCaptureWindows()
            case .screenLocked:
                features.capture.interrupt(because: .screenLocked)
                features.scroll.interrupt(because: .screenLocked)
            case .sleeping:
                features.capture.cancel()
            }
        }
        monitor.start()
        systemEvents = monitor
        recognizeText = { [editors] session in
            editors.open(session, environment: environment, initialAction: .recognizeText)
        }
        prepareCaptureWindows()
    }

    /// Pre-builds the windows a capture shows (A-13 step 2) on a later main-actor turn, so launch
    /// and a display change finish first.
    private func prepareCaptureWindows() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            captureUI?.prepareOverlays(features.services.capture.displays())
            editors.prepareSpare()
        }
    }

    func handleCapture(_ completion: CaptureCompletion) {
        // Decided here, synchronously, before anything else can run on the main actor: a setting
        // changed by a job queued after this belongs to the next capture (R-3, ADR-009).
        switch CaptureFollowUp.decide(purpose: completion.purpose, preferences: settings.preferences) {
        case .editor(let masks):
            let plan = features.export.automaticExportPlan()
            // Opening orders the editor window front before it returns.
            let toEditor = LatencySignposts.begin(.captureToEditor)
            let editor = openDocument?(completion.session, masks ? .maskSensitiveText : .none, nil)
            toEditor.end()
            runAutomaticExports(plan, for: completion.session, editor: editor, masks: masks)
        case .quickActions:
            showQuickActions(completion.session, plan: features.export.automaticExportPlan())
        case .recognizeText:
            recognizeText?(completion.session)
        }
    }

    /// The thumbnail shows once the capture's automatic batch has run; without an editor, every
    /// failure of that batch is an alert.
    private func showQuickActions(_ session: DocumentSession, plan: AutomaticExportPlan) {
        let quickActions = features.quickActions
        automaticExportsInFlight += 1
        Task {
            defer { automaticExportsInFlight -= 1 }
            let outcomes = await quickActions.present(session, after: plan)
            reportAutomaticExport(outcomes, from: nil)
        }
    }

    /// Auto-copy/auto-save run on the fresh capture, before any later edit, and only when enabled.
    /// With an editor they run through it: on the masked document when `masks`, after the masks
    /// land, and freshness is checked against its live session, so an edit made while the export
    /// renders, or closing the editor, keeps the earlier state from being sent.
    private func runAutomaticExports(
        _ plan: AutomaticExportPlan, for session: DocumentSession, editor: EditorModel?, masks: Bool
    ) {
        guard !plan.isEmpty else { return }
        let export = features.export
        // Counted until reported, so quitting after the last window waits for the save and shows
        // its failure first.
        automaticExportsInFlight += 1
        Task {
            defer { automaticExportsInFlight -= 1 }
            let outcomes: [ExportOutcome]
            if let editor {
                outcomes = await editor.runAutomaticExports(plan)
            } else if masks {
                // Nothing could mask this capture, so nothing exports it automatically.
                outcomes = [.failed(.maskingUnfinished)]
            } else {
                outcomes = await export.runAutomaticExports(plan, for: session, currentSession: { session })
            }
            reportAutomaticExport(outcomes, from: editor)
        }
    }

    /// Reports an automatic batch's results as `routeAutomaticExport` routes them. A message about
    /// an editor is a sheet on its window while the person can see it, else an app alert.
    func reportAutomaticExport(_ outcomes: [ExportOutcome], from editor: EditorModel?) {
        let route = Self.routeAutomaticExport(outcomes, editorOpen: editor.map { !$0.isClosed } ?? false)
        for failure in route.messages { showMessage(.export(failure), messageTarget(for: editor)) }
        // The masking count keeps the editor's notice slot (T1 security 3C): a failure the
        // editor refuses is raised as a message, so it is never lost either.
        for outcome in route.editorNotices where editor?.reportAutomaticExport(outcome) != true {
            if case .failed(let failure) = outcome { showMessage(.export(failure), messageTarget(for: editor)) }
        }
    }

    /// Decided when each message is shown, so an editor closed or hidden meanwhile gets an alert.
    private func messageTarget(for editor: EditorModel?) -> MessageTarget {
        guard let editor, let window = editorWindow(editor) else { return .app }
        let onScreen = window.isVisible && !window.isMiniaturized && window.isOnActiveSpace
        return MessagePlacement(editorIsOpen: !editor.isClosed, windowIsOnScreen: onScreen) == .editorSheet
            ? .sheet(window) : .app
    }

    /// Where automatic-export results are reported. The editor has one notice slot, so it shows a
    /// failure only when that is the batch's only report; otherwise failures become messages
    /// (sheets or alerts), so none is hidden behind another notice, and an upload link keeps the
    /// editor slot.
    static func routeAutomaticExport(_ outcomes: [ExportOutcome], editorOpen: Bool) -> (
        editorNotices: [ExportOutcome], messages: [ExportFailure]
    ) {
        var failures: [ExportFailure] = []
        for case .failed(let failure) in outcomes { failures.append(failure) }
        let uploads = outcomes.filter { $0.uploadedURL != nil }
        guard editorOpen else { return ([], failures) }
        if uploads.isEmpty, failures.count == 1 { return (failures.map { .failed($0) }, []) }
        return (uploads, failures)
    }

    private func startScrollingCapture() {
        let scroll = features.scroll
        isStartingScrollingCapture = true
        Task {
            // Permission denial can leave the scroll model idle without an observed transition.
            defer {
                isStartingScrollingCapture = false
                captureWindowVisibility?.restoreIfFinished()
            }
            if !(await scroll.begin()), scroll.notice == .screenPermissionDenied {
                showMessage(.capture(.permissionDenied), .app)
            }
        }
    }

    private func toggleScrollingCapture() {
        let scroll = features.scroll
        switch scroll.state {
        case .collecting, .paused: scroll.stop()
        case .armed: scroll.start()
        case .selecting: scroll.cancel()
        default: perform(.scrollingCapture)
        }
    }

    private func chooseImageFile() {
        AppPresence.shared.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a PNG or JPEG image to open.")
        // A finished open panel is ordered out, not closed: re-evaluate the Dock presence.
        defer { AppPresence.shared.setNeedsRefresh() }
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
        // Leaving Recortia is when a person goes to System Settings to free a held key.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchHeldShortcuts(restart: true) }
        }
    }

    /// Registers or holds every shortcut. Holding one starts a two-second watch (`onHold`), so a
    /// default starts working soon after the user turns the macOS shortcut off (ADR-005).
    func refreshShortcuts() {
        shortcutStatus.refreshAll()
        watchHeldShortcuts(restart: true)
    }

    /// Restore Defaults in Settings: the macOS-style table, every other command cleared.
    func restoreDefaultShortcuts() {
        shortcutStatus.reassign { ShortcutDefaults.restore() }
    }

    /// Quick at first (the user may be in System Settings freeing the key), then backing off to
    /// one check every 10 s, so a default install that keeps macOS's shortcuts wakes far less often
    /// (ADR-005). Activation, resigning active and opening shortcut settings restart quick checks.
    static func heldShortcutPollDelay(afterChecks checks: Int) -> Duration {
        .seconds(min(2 << min(max(checks, 0), 3), 10))
    }

    private func watchHeldShortcuts(restart: Bool = false) {
        guard shortcutStatus.isHoldingAny else {
            heldShortcutWatch?.cancel()
            heldShortcutWatch = nil
            return
        }
        if restart {
            heldShortcutWatch?.cancel()
            heldShortcutWatch = nil
        }
        guard heldShortcutWatch == nil else { return }
        heldShortcutWatch = Task { [weak self] in
            var checks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heldShortcutPollDelay(afterChecks: checks))
                checks += 1
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

/// What quitting now would discard: editors whose edits were never exported, and a scrolling
/// capture waiting in its review.
struct QuitDiscards: Hashable {
    var editedImages: Int
    var scrollingReview: Bool

    var isEmpty: Bool { editedImages == 0 && !scrollingReview }
}
