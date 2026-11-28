import CoreGraphics
import Domain
import Foundation
import Imaging
import MacPlatform
import Observation

public enum CapturePurpose: Hashable, Sendable {
    case edit
    case recognizeText
}

/// A finished capture, delivered once to `onCaptured`.
public struct CaptureCompletion: Sendable {
    public let requestID: RequestID
    public let session: DocumentSession
    public let purpose: CapturePurpose
}

/// Pure region-selection rules shared by the coordinator and the overlay (FR-02).
public enum RegionSelection {
    /// Minimum committed size in points; smaller drags (a click) do not capture.
    public static let minimumSide = 1.0

    /// Clamps `rect` to `display` (v1 regions never cross displays). Returns nil when nothing
    /// usable remains; `wasClamped` tells the overlay to explain the limitation.
    public static func clamp(_ rect: Rect<DesktopSpace>, to display: DisplayInfo) -> (
        rect: Rect<DesktopSpace>, wasClamped: Bool
    )? {
        guard (try? rect.validated()) != nil, let clipped = rect.intersection(display.frame) else { return nil }
        guard clipped.width >= minimumSide, clipped.height >= minimumSide else { return nil }
        return (clipped, clipped != rect)
    }

    /// Size of `rect` in the display's actual pixels (never an assumed 2x), from the same
    /// outward-snapped rectangle the capture takes.
    public static func pixelSize(of rect: Rect<DesktopSpace>, on display: DisplayInfo) -> PixelSize {
        guard let local = DesktopGeometry.pixelAlignedLocalRect(rect, on: display) else {
            return PixelSize(width: 0, height: 0)
        }
        let scale = display.pointPixelScale
        let width = (local.width * scale).rounded(), height = (local.height * scale).rounded()
        guard width < Double(Int32.max), height < Double(Int32.max) else { return PixelSize(width: 0, height: 0) }
        return PixelSize(width: Int(width), height: Int(height))
    }
}

/// Drives `CaptureState` for one capture at a time (SPEC §6, FR-02, CAP-02, PERM-01/02).
///
/// Replacement policy: a new invocation while checking permission, selecting, or counting down
/// cancels the current session and starts the new one. While capturing, a new invocation is
/// ignored and reported through `notice`, because the one-shot capture is already committed.
/// Nothing is queued. Every asynchronous completion carries the session's request ID and is
/// dropped when that session is no longer current, so a late result never opens an editor.
@MainActor
@Observable
public final class CaptureCoordinator {
    public enum StartResult: Hashable, Sendable {
        case started
        case replacedPrevious
        case ignoredCaptureInProgress
    }

    public enum SelectionContext: Hashable, Sendable {
        case region([DisplayInfo])
        case display([DisplayInfo])
        case loadingWindows
        case window([WindowInfo])
    }

    public enum Notice: Hashable, Sendable {
        case captureInProgress
        case freezeBusy
        case freezeExpired
        case freezeUnavailable
        /// The remembered region's display changed or disappeared; a new selection is needed.
        case repeatRegionUnavailable
    }

    public struct FrozenFrame: Sendable {
        public let display: DisplayInfo
        public let image: CGImage
        fileprivate let geometry: CaptureGeometry
    }

    public enum RegionFreeze: Sendable {
        case preparing(DisplayInfo)
        case frozen(FrozenFrame)

        public var display: DisplayInfo {
            switch self {
            case .preparing(let display): display
            case .frozen(let frame): frame.display
            }
        }
    }

    /// Delay used by Capture with Delay when the preference is 0 seconds.
    public static let fallbackDelaySeconds = 5
    private static let freezeLifetime: Duration = .seconds(60)
    /// How long a capture waits for a canceled display read to return before failing.
    static let freezeReadDrainLimit: Duration = .seconds(10)

    public private(set) var state: CaptureState = .idle
    public private(set) var mode: CaptureMode?
    public private(set) var purpose: CapturePurpose = .edit
    public private(set) var selectionContext: SelectionContext?
    public private(set) var notice: Notice?
    public private(set) var regionFreeze: RegionFreeze?
    /// Frames of other apps' on-screen windows that a region selection snaps to (A-4), then the
    /// interface elements of the app under the pointer when that setting is on (B-7); empty until
    /// listed, outside a region selection, and when listing fails. Held for one selection only.
    public private(set) var snapFrames: [Rect<DesktopSpace>] = []
    private(set) var lastSelectionWasClamped = false
    private var repeatRegion: RepeatRegion?

    @ObservationIgnored public var onCaptured: ((CaptureCompletion) -> Void)?

    @ObservationIgnored private let capture: any CaptureService
    @ObservationIgnored private let permission: any ScreenPermissionService
    @ObservationIgnored private let assets: any ImageAssetService
    @ObservationIgnored private let clock: any FeatureClock
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let sound: (any CaptureSoundService)?
    @ObservationIgnored private let elements: (any InterfaceElementFrameService)?
    @ObservationIgnored private let diagnostics: (any DiagnosticsSink)?
    /// When the current request started, for the diagnostics file's durations.
    @ObservationIgnored private var startedAt: Duration = .zero
    /// The current request's start-to-overlay interval (A-13).
    @ObservationIgnored private var overlayInterval: LatencyInterval?
    /// Each capture call's own interval, so a stale one closes only its own.
    @ObservationIgnored private var captureIntervals: [RequestID: LatencyInterval] = [:]
    @ObservationIgnored private var active: ActiveCapture?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var snapTask: Task<Void, Never>?
    @ObservationIgnored private var freezeRead: Task<Void, Never>?
    @ObservationIgnored private var freezePermissionCheck: Task<Void, Never>?
    @ObservationIgnored private var freezeExpiry: Task<Void, Never>?
    @ObservationIgnored private var freezeDeadline: Duration?

    private struct ActiveCapture {
        let id: RequestID
        let delaySeconds: Int
        let startingMode: CaptureMode
        var committedFrozenFrame: FrozenFrame? = nil
    }

    private enum CapturePixels {
        case raw(CGImage)
        case canonical(DecodedImage)
    }

    /// Session-only memory for Repeat Last Region, bound to the display's identity and configuration.
    private struct RepeatRegion {
        let rect: Rect<DesktopSpace>
        let displayID: CGDirectDisplayID
        let fingerprint: String
    }

    public init(
        capture: any CaptureService, permission: any ScreenPermissionService, assets: any ImageAssetService,
        clock: any FeatureClock, settings: SettingsStore, sound: (any CaptureSoundService)?,
        elements: (any InterfaceElementFrameService)?, diagnostics: (any DiagnosticsSink)? = nil
    ) {
        self.capture = capture
        self.permission = permission
        self.assets = assets
        self.clock = clock
        self.settings = settings
        self.sound = sound
        self.elements = elements
        self.diagnostics = diagnostics
    }

    public var hasRepeatRegion: Bool { repeatRegion != nil }

    /// The ratio region selections keep; the person's last choice (A-4).
    public var regionAspect: SelectionAspect { settings.preferences.regionAspect }

    public func setRegionAspect(_ aspect: SelectionAspect) {
        settings.update { $0.regionAspect = aspect }
    }

    public var delayForDelayedCapture: Int {
        let configured = settings.preferences.captureDelaySeconds
        return configured > 0 ? configured : Self.fallbackDelaySeconds
    }

    // MARK: Commands

    public var canFreezeRegion: Bool {
        state == .selecting && mode == .region && active?.startingMode == .region
            && purpose == .edit && active?.delaySeconds == 0
    }

    public func toggleRegionFreeze(on display: DisplayInfo?) {
        guard canFreezeRegion, let active else { return }
        if regionFreeze != nil {
            discardFrozenRegion()
            return
        }
        guard freezeRead == nil else {
            notice = .freezeBusy
            return
        }
        guard let display, case .region(let displays) = selectionContext,
            displays.contains(display)
        else { return }
        guard permission.isGranted else {
            interrupt(because: .permissionDenied)
            return
        }

        notice = nil
        let deadline = clock.uptime() + Self.freezeLifetime
        freezeDeadline = deadline
        regionFreeze = .preparing(display)
        freezeExpiry = Task { [weak self, clock] in
            // A timer can return early; only the monotonic deadline ends the preview.
            while clock.uptime() < deadline {
                do { try await clock.sleep(for: deadline - clock.uptime()) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self?.expireFrozenRegion()
        }
        freezeRead = Task { [weak self] in
            guard let self else { return }
            defer { self.freezeRead = nil }
            await self.acquireFrozenFrame(on: display, id: active.id)
        }
        freezePermissionCheck = Task { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                if !self.permission.isGranted {
                    self.interrupt(because: .permissionDenied)
                    return
                }
            }
        }
    }

    @discardableResult
    public func start(_ mode: CaptureMode, delaySeconds: Int = 0, purpose: CapturePurpose = .edit) -> StartResult {
        if state == .capturing {
            notice = .captureInProgress
            return .ignoredCaptureInProgress
        }
        let replaced = state.isActive
        if replaced { abortActive() }
        if !state.isActive, state != .idle { apply(.reset) }

        overlayInterval = LatencySignposts.begin(.startToOverlay)
        let id = RequestID()
        active = ActiveCapture(id: id, delaySeconds: CaptureRequest.clampedDelay(delaySeconds), startingMode: mode)
        self.mode = mode
        self.purpose = purpose
        notice = nil
        lastSelectionWasClamped = false
        let isGranted = permission.isGranted
        diagnostics?.record(.permissionStatus(permission: .screenRecording, granted: isGranted))
        apply(.request)

        if isGranted {
            beginSelection(id)
        } else {
            task = Task { [weak self] in
                guard let self else { return }
                let granted = await self.permission.request()
                self.diagnostics?.record(.permissionStatus(permission: .screenRecording, granted: granted))
                guard self.isCurrent(id) else { return }
                if granted {
                    self.beginSelection(id)
                } else {
                    self.apply(.permissionDenied)
                    self.finish()
                }
            }
        }
        return replaced ? .replacedPrevious : .started
    }

    /// Commits a region drawn on `display`, clamped to that display. Returns false (and keeps
    /// selecting) when the drag is empty or entirely off the display.
    @discardableResult
    public func commitRegion(_ rect: Rect<DesktopSpace>, on display: DisplayInfo) -> Bool {
        guard state == .selecting, let clamped = RegionSelection.clamp(rect, to: display) else { return false }
        lastSelectionWasClamped = clamped.wasClamped
        return commitSelection(.region(clamped.rect, display: display))
    }

    @discardableResult
    public func commitSelection(_ target: CaptureTarget) -> Bool {
        guard state == .selecting, let active, !expireFrozenRegion() else { return false }
        switch regionFreeze {
        case .preparing:
            return false
        case .frozen(let frame):
            guard case .region(_, let display) = target, display == frame.display else { return false }
            do throws(CaptureError) {
                try verifyFrozenDisplay(display)
            } catch {
                handle(error)
                return false
            }
            self.active?.committedFrozenFrame = frame
        case nil: break
        }
        let drainingRead = freezeRead
        discardFrozenRegion()
        abandonOverlayInterval()
        selectionContext = nil
        forgetSnapFrames()
        apply(.selectionCommitted(delaySeconds: active.delaySeconds))
        let id = active.id
        task = Task { [weak self, clock] in
            // ScreenCaptureKit can complete a canceled read later. The next capture waits for it
            // to return, never runs beside it, and fails if the read is still out at the limit.
            if let drainingRead,
                await !DrainRace().wait(for: drainingRead, within: Self.freezeReadDrainLimit, clock: clock)
            {
                guard let self, self.isCurrent(id) else { return }
                self.handle(.targetUnavailable)
                return
            }
            await self?.run(target, id: id)
        }
        return true
    }

    /// Space during a region selection, as in the macOS Screenshot app: the same request (and its
    /// delay) continues as a window selection. Only a plain region selection switches; Capture
    /// Text and other modes return false and keep selecting.
    @discardableResult
    public func switchToWindowSelection() -> Bool {
        guard state == .selecting, mode == .region, purpose == .edit, let active else { return false }
        discardFrozenRegion()
        forgetSnapFrames()
        mode = .window
        selectionContext = .loadingWindows
        let id = active.id
        task = Task { [weak self] in await self?.loadWindows(id) }
        return true
    }

    /// Escape or Cancel. Has no effect when nothing is active; never implies copy or save.
    public func cancel() {
        guard state.isActive else { return }
        abortActive()
    }

    /// Display added, removed, rotated, or rescaled: forget the repeat region and stop any
    /// selection, countdown, or capture that depended on the old arrangement.
    public func displayConfigurationChanged() {
        repeatRegion = nil
        interrupt(because: .displayChanged)
    }

    /// Screen lock or permission loss reported by the app while a capture is active.
    public func interrupt(because failure: CaptureFailure) {
        switch state {
        case .selecting, .countdown, .capturing:
            task?.cancel()
            task = nil
            active = nil
            apply(.captureFailed(failure))
            finish()
        case .permissionCheck:
            abortActive()
        default:
            break
        }
    }

    func clearNotice() { notice = nil }

    // MARK: Flow

    private func beginSelection(_ id: RequestID) {
        apply(.permissionGranted)
        switch mode {
        case .region, nil:
            selectionContext = .region(capture.displays())
            loadSnapFrames(id)
        case .repeatRegion:
            let displays = capture.displays()
            if let memory = repeatRegion,
                let display = displays.first(where: {
                    $0.id == memory.displayID && $0.fingerprint == memory.fingerprint
                })
            {
                commitSelection(.region(memory.rect, display: display))
            } else {
                repeatRegion = nil
                notice = .repeatRegionUnavailable
                mode = .region
                selectionContext = .region(displays)
                loadSnapFrames(id)
            }
        case .display:
            let displays = capture.displays()
            if displays.count == 1, let only = displays.first {
                commitSelection(.display(only))
            } else if displays.isEmpty {
                apply(.captureFailed(.targetUnavailable))
                finish()
            } else {
                selectionContext = .display(displays)
            }
        case .window:
            selectionContext = .loadingWindows
            task = Task { [weak self] in await self?.loadWindows(id) }
        }
    }

    private func loadWindows(_ id: RequestID) async {
        do throws(CaptureError) {
            let windows = try await capture.windows()
            guard isCurrent(id), state == .selecting else { return }
            selectionContext = .window(windows)
        } catch {
            guard isCurrent(id) else { return }
            handle(error)
        }
    }

    /// Lists window frames for snapping alongside the region overlay, then, with element snapping
    /// on as the selection starts, the element frames of the app under the pointer. A failed list
    /// or read only leaves that snapping off: display edges and the window frames already listed
    /// still snap, and the selection itself depends on neither. A result is accepted only while
    /// the same request is still selecting a region.
    private func loadSnapFrames(_ id: RequestID) {
        let snapsToElements = settings.preferences.snapsToInterfaceElements
        snapTask = Task { [weak self] in
            guard let self else { return }
            guard let windows = try? await self.capture.windows(), self.isSelectingRegion(id) else { return }
            let windowFrames = windows.map(\.frame)
            self.snapFrames = windowFrames
            guard snapsToElements, let elements = self.elements, case .region(let displays)? = self.selectionContext,
                let walk = await elements.frames(under: windows), self.isSelectingRegion(id)
            else { return }
            self.snapFrames = windowFrames + ElementSnapping.admitted(walk.frames, displays: displays.map(\.frame))
        }
    }

    private func isSelectingRegion(_ id: RequestID) -> Bool {
        isCurrent(id) && state == .selecting && mode == .region
    }

    private func acquireFrozenFrame(on display: DisplayInfo, id: RequestID) async {
        guard isSelectingRegion(id), !expireFrozenRegion() else { return }
        let preferences = settings.preferences
        do throws(CaptureError) {
            let (image, geometry) = try await capture.capture(
                .display(display), showsCursor: preferences.captureShowsCursor,
                includesShadow: preferences.captureIncludesWindowShadow)
            guard isSelectingRegion(id), !expireFrozenRegion() else { return }
            try verifyFrozenDisplay(display)
            guard geometry.source == .display(id: display.id),
                geometry.desktopBounds == display.frame,
                abs(geometry.pointPixelScale - display.pointPixelScale) <= 0.001
            else { throw .displayChanged }
            let size = PixelSize(width: image.width, height: image.height)
            guard ImportLimits.check(pixelSize: size) == nil, geometry.pixelSize == size,
                (display.frame.width * geometry.pointPixelScale).rounded() == Double(size.width),
                (display.frame.height * geometry.pointPixelScale).rounded() == Double(size.height)
            else { throw .targetUnavailable }
            regionFreeze = .frozen(FrozenFrame(display: display, image: image, geometry: geometry))
        } catch {
            guard isSelectingRegion(id) else { return }
            switch error {
            case .permissionDenied, .displayChanged:
                handle(error)
            case .targetUnavailable, .system, .canceled:
                guard !expireFrozenRegion() else { return }
                discardFrozenRegion()
                notice = .freezeUnavailable
            }
        }
    }

    private func verifyFrozenDisplay(_ display: DisplayInfo) throws(CaptureError) {
        guard permission.isGranted else { throw .permissionDenied }
        guard capture.displays().contains(display) else { throw .displayChanged }
    }

    private func takeFrozenCrop(for target: CaptureTarget) async throws(CaptureError) -> (DecodedImage, CaptureGeometry)
    {
        guard let frame = active?.committedFrozenFrame else { throw .canceled }
        active?.committedFrozenFrame = nil
        return try await Self.cropFrozenRegion(frame, target: target)
    }

    @concurrent private static func cropFrozenRegion(_ frame: FrozenFrame, target: CaptureTarget)
        async throws(CaptureError) -> (DecodedImage, CaptureGeometry)
    {
        guard case .region(let rect, let display) = target, display == frame.display else { throw .targetUnavailable }
        let scale = frame.geometry.pointPixelScale
        let sourceDisplay = DisplayInfo(
            id: display.id, frame: display.frame, pointPixelScale: scale, fingerprint: display.fingerprint)
        guard let local = DesktopGeometry.pixelAlignedLocalRect(rect, on: sourceDisplay) else {
            throw .targetUnavailable
        }
        let pixels = CGRect(
            x: (local.minX * scale).rounded(), y: (local.minY * scale).rounded(),
            width: (local.width * scale).rounded(), height: (local.height * scale).rounded())
        guard let cropped = frame.image.cropping(to: pixels),
            Double(cropped.width) == pixels.width, Double(cropped.height) == pixels.height
        else { throw .targetUnavailable }
        // CGImage.cropping retains the full source. Canonicalization allocates the same independent,
        // color-managed raster as an ordinary capture before the asset service receives the crop.
        guard let independent = try? ImageDecoder.canonicalize(cropped) else { throw .system(code: -1) }
        return (
            independent,
            CaptureGeometry(
                source: .region(displayID: display.id),
                desktopBounds: Rect(
                    x: display.frame.minX + local.minX, y: display.frame.minY + local.minY,
                    width: local.width, height: local.height),
                pointPixelScale: scale, pixelSize: PixelSize(width: cropped.width, height: cropped.height),
                capturedAt: frame.geometry.capturedAt)
        )
    }

    private func run(_ target: CaptureTarget, id: RequestID) async {
        while case .countdown = state {
            do {
                try await clock.sleep(for: .seconds(1))
            } catch {
                return  // canceled or replaced; the canceling side already moved the state
            }
            guard isCurrent(id) else { return }
            apply(.countdownTick)
        }
        guard isCurrent(id), state == .capturing else { return }

        let preferences = settings.preferences
        let frozenDisplay = active?.committedFrozenFrame?.display
        let captured: (CapturePixels, CaptureGeometry)
        captureIntervals[id] = LatencySignposts.begin(.selectionToCapture)
        do throws(CaptureError) {
            if let frozenDisplay {
                let (image, geometry) = try await takeFrozenCrop(for: target)
                captured = (.canonical(image), geometry)
                guard isCurrent(id) else { throw .canceled }
                try verifyFrozenDisplay(frozenDisplay)
            } else {
                let (image, geometry) = try await capture.capture(
                    target, showsCursor: preferences.captureShowsCursor,
                    includesShadow: preferences.captureIncludesWindowShadow)
                captured = (.raw(image), geometry)
            }
            captureIntervals.removeValue(forKey: id)?.end()
        } catch {
            captureIntervals.removeValue(forKey: id)?.abandon()
            guard isCurrent(id) else { return }
            handle(error)
            return
        }
        guard isCurrent(id) else { return }

        let info: ImageAssetInfo
        do {
            switch captured.0 {
            case .raw(let image):
                info = try await assets.registerCapture(image, geometry: captured.1)
            case .canonical(let image):
                info = try await assets.registerCapture(image, geometry: captured.1)
            }
        } catch {
            guard isCurrent(id) else { return }
            // Canonicalization failed; report a system failure without inventing an image.
            apply(.captureFailed(.system(code: -1)))
            finish()
            return
        }
        guard isCurrent(id) else {
            assets.release(info.id)
            return
        }
        if let frozenDisplay {
            do throws(CaptureError) {
                try verifyFrozenDisplay(frozenDisplay)
            } catch {
                assets.release(info.id)
                handle(error)
                return
            }
        }

        if case .region(let rect, let display) = target {
            repeatRegion = RepeatRegion(rect: rect, displayID: display.id, fingerprint: display.fingerprint)
        }
        let completion = CaptureCompletion(
            requestID: id,
            session: DocumentSession(
                document: Document(
                    capture: info, windowBackground: preferences.windowCaptureBackground,
                    defaultFraming: preferences.defaultFraming)),
            purpose: purpose)
        apply(.captureSucceeded)
        if let mode {
            diagnostics?.record(
                .captureFinished(
                    mode: DiagnosticCaptureMode(mode), purpose: DiagnosticCapturePurpose(purpose),
                    duration: clock.uptime() - startedAt, width: info.pixelSize.width, height: info.pixelSize.height))
        }
        finish()
        // A capture to edit, not Capture Text: its result is copied text, not a screenshot.
        if purpose == .edit, settings.preferences.playsCaptureSound { sound?.playCaptureSound() }
        onCaptured?(completion)
    }

    private func handle(_ error: CaptureError) {
        switch error {
        case .canceled:
            apply(.cancel)
        case .permissionDenied:
            apply(.captureFailed(.permissionDenied))
        case .targetUnavailable:
            apply(.captureFailed(.targetUnavailable))
        case .displayChanged:
            repeatRegion = nil
            apply(.captureFailed(.displayChanged))
        case .system(let code):
            apply(.captureFailed(.system(code: code)))
        }
        finish()
    }

    // MARK: Bookkeeping

    private func isCurrent(_ id: RequestID) -> Bool {
        active?.id == id && !Task.isCancelled
    }

    /// The overlay or chooser for the current request is on screen.
    public func selectionDidAppear() {
        overlayInterval?.end()
        overlayInterval = nil
    }

    /// Ends the current request's overlay interval when it finishes without one (Repeat Last
    /// Region, a single display, a cancel); after `selectionDidAppear` this does nothing.
    private func abandonOverlayInterval() {
        overlayInterval?.abandon()
        overlayInterval = nil
    }

    #if DEBUG
        /// The latency intervals still open, for tests.
        var openLatencyIntervals: [LatencySignposts.Interval] {
            captureIntervals.values.filter(\.isOpen).map(\.kind) + (overlayInterval.map { [$0.kind] } ?? [])
        }
    #endif

    private func abortActive() {
        abandonOverlayInterval()
        task?.cancel()
        task = nil
        active = nil
        selectionContext = nil
        discardFrozenRegion()
        forgetSnapFrames()
        apply(.cancel)
    }

    private func finish() {
        abandonOverlayInterval()
        active = nil
        task = nil
        selectionContext = nil
        discardFrozenRegion()
        forgetSnapFrames()
    }

    @discardableResult
    private func expireFrozenRegion() -> Bool {
        guard let freezeDeadline, clock.uptime() >= freezeDeadline, let regionFreeze else { return false }
        do throws(CaptureError) {
            try verifyFrozenDisplay(regionFreeze.display)
        } catch {
            handle(error)
            return true
        }
        discardFrozenRegion()
        notice = .freezeExpired
        return true
    }

    private func discardFrozenRegion() {
        freezeRead?.cancel()
        freezePermissionCheck?.cancel()
        freezePermissionCheck = nil
        freezeExpiry?.cancel()
        freezeExpiry = nil
        freezeDeadline = nil
        if regionFreeze != nil { regionFreeze = nil }
    }

    private func forgetSnapFrames() {
        snapTask?.cancel()
        snapTask = nil
        if !snapFrames.isEmpty { snapFrames = [] }
    }

    private func apply(_ event: CaptureEvent) {
        do {
            state = try state.next(event)
        } catch {
            // An illegal transition is a programming error; keep the last valid state.
            assertionFailure("\(error)")
            return
        }
        recordDiagnostics(event)
    }

    /// Start, cancellation and failure; success is recorded with the image size in `run`.
    private func recordDiagnostics(_ event: CaptureEvent) {
        guard let diagnostics, let current = self.mode else { return }
        let mode = DiagnosticCaptureMode(current)
        switch event {
        case .request:
            startedAt = clock.uptime()
            diagnostics.record(.captureStarted(mode: mode, purpose: DiagnosticCapturePurpose(purpose)))
        case .cancel:
            diagnostics.record(.captureCancelled(mode: mode, duration: clock.uptime() - startedAt))
        case .captureFailed(let failure):
            diagnostics.record(
                .captureFailed(
                    mode: mode, failure: DiagnosticCaptureFailure(failure), duration: clock.uptime() - startedAt))
        case .permissionDenied:
            diagnostics.record(
                .captureFailed(mode: mode, failure: .permissionDenied, duration: clock.uptime() - startedAt))
        case .permissionGranted, .selectionCommitted, .countdownTick, .countdownFinished, .captureSucceeded, .reset:
            break
        }
    }
}

/// Waits for a task to finish or a clock deadline, whichever comes first. Awaiting `Task.value`
/// ignores the waiter's cancellation, so the read is raced from a separate task.
@MainActor
private final class DrainRace {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var racers: [Task<Void, Never>] = []

    /// True when `task` finished within `limit`; false at the limit or when the waiter is canceled.
    func wait(for task: Task<Void, Never>, within limit: Duration, clock: FeatureClock) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                racers = [
                    Task {
                        await task.value; self.finish(true)
                    },
                    Task {
                        do { try await clock.sleep(for: limit) } catch { return }
                        self.finish(false)
                    },
                ]
            }
        } onCancel: {
            Task { @MainActor in self.finish(false) }
        }
    }

    private func finish(_ drained: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        for racer in racers { racer.cancel() }
        continuation.resume(returning: drained)
    }
}
