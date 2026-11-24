import CoreGraphics
import Domain
import Foundation
import Imaging
import MacPlatform
import Observation

public enum ScrollMode: Hashable, Sendable {
    case manual
    case automatic
}

/// Drives `ScrollState` over a frame source, a stitcher, and an optional auto scroller (FR-10).
///
/// The session stitches along `direction`, read from Settings when the area is chosen and
/// changeable only until Start: down by default, or to the right for a wide page.
///
/// Manual scrolling always works. Automatic scrolling runs only when the user enabled it and the
/// process is trusted for Accessibility; otherwise the session explains why and stays manual.
/// Ambiguous matches pause instead of appending, a reached limit ends collection into review
/// with a partial reason, and target loss, display change, or permission revocation stop the
/// stream immediately. Frames that arrive after Stop or Cancel are dropped.
///
/// Endings that do not depend on a frame arriving run on the injected clock: the 2-minute limit
/// counts from Start, paused time included, and in automatic mode a scroll step that exposes
/// nothing new within `automaticSettleInterval` counts as the page not moving (the capture
/// stream delivers no frame for unchanged content). After `ScrollStitcher.endOfPageStationaryFrames`
/// consecutive stationary frames or unanswered steps the page stopped moving: complete only if the
/// target confirms its scroll area is at its end, and partial (`.stoppedMoving`) otherwise. Manual mode only raises `pageEndLikely`, since a reader may simply stop.
@MainActor
@Observable
public final class ScrollSessionModel {
    public enum Notice: Hashable, Sendable {
        case screenPermissionDenied
        /// Automatic scrolling is enabled in Settings but Accessibility is not granted.
        case automaticNeedsAccessibility
        /// Accessibility was revoked mid-session; the session continues manually.
        case accessibilityRevoked
        /// The stitched image could not be assembled within its budget.
        case assemblyFailed
    }

    /// Longest side of the review's preview, along the scroll direction.
    static let previewMaxLength = 2_000

    public private(set) var state: ScrollState = .idle
    public private(set) var mode: ScrollMode = .manual
    public private(set) var direction: ScrollCaptureDirection = .vertical
    public private(set) var notice: Notice?
    public private(set) var target: CaptureTarget?
    public private(set) var acceptedFrames = 0
    public private(set) var outputSize = PixelSize(width: 0, height: 0)
    /// Output rows (columns, horizontally) where one accepted frame joins the next, for the
    /// review's seam markers.
    public private(set) var seams: [Int] = []
    public private(set) var partialReason: ScrollPartialReason?
    public private(set) var preview: CGImage?
    /// Manual mode: the page stopped moving, so it may have ended. A hint only; the user stops.
    public private(set) var pageEndLikely = false

    /// Automatic mode: how long after a scroll step a new frame must arrive before the step
    /// counts as exposing nothing new.
    static let automaticSettleInterval: Duration = .milliseconds(1_500)
    static let maxDuration = ScrollLimits.default.maxDuration

    /// Receives the accepted capture and whether its e-mail addresses and phone numbers are to be
    /// masked before it is shown (FR-06), read once when the document is created.
    @ObservationIgnored public var onAccepted: ((DocumentSession, _ masksSensitiveText: Bool) -> Void)?

    @ObservationIgnored private let frames: any ScrollFrameSourceService
    @ObservationIgnored private let stitcher: any ScrollStitchService
    @ObservationIgnored private let autoScroller: (any AutoScrollService)?
    @ObservationIgnored private let accessibility: any AccessibilityPermissionService
    @ObservationIgnored private let screenPermission: any ScreenPermissionService
    @ObservationIgnored private let assets: any ImageAssetService
    @ObservationIgnored private let clock: any FeatureClock
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let diagnostics: (any DiagnosticsSink)?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var streamStarted = false
    /// The session that last started the frame source; a stale session stops only its own stream.
    @ObservationIgnored private var streamOwner: UUID?
    /// `clock.uptime()` at Start; durations never use the wall clock.
    @ObservationIgnored private var startedAt: Duration?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var unansweredSteps = 0
    @ObservationIgnored private var autoStepOwner: UUID?
    /// True while the collection loop awaits `stitcher.append`; the stitcher may still mutate.
    @ObservationIgnored private var appendInFlight = false
    /// A Stop (or other ending) that arrived while an append was in flight. The stream is already
    /// stopped; the review is frozen once that append settles, so its rows, seam, and counters
    /// land in one snapshot.
    @ObservationIgnored private var pendingFinish: PendingFinish?
    /// The session whose Accept is assembling; admitted before the first await, so a repeated
    /// Accept cannot start a second full-size assembly.
    private var acceptingSession: UUID?

    /// How collection is to end once the admitted append settles.
    private struct PendingFinish {
        var partial: ScrollPartialReason?
        var event: ScrollEvent
    }

    public init(
        frames: any ScrollFrameSourceService, stitcher: any ScrollStitchService, autoScroller: (any AutoScrollService)?,
        accessibility: any AccessibilityPermissionService, screenPermission: any ScreenPermissionService,
        assets: any ImageAssetService, clock: any FeatureClock, settings: SettingsStore,
        diagnostics: (any DiagnosticsSink)? = nil
    ) {
        self.frames = frames
        self.stitcher = stitcher
        self.autoScroller = autoScroller
        self.accessibility = accessibility
        self.screenPermission = screenPermission
        self.assets = assets
        self.clock = clock
        self.settings = settings
        self.diagnostics = diagnostics
    }

    public var isPartial: Bool { partialReason != nil }

    /// Accept needs a shown preview (the person reviews the seams first), no Accept in progress,
    /// and no failed assembly: a stitch over its budget fails the same way again, so the person
    /// discards instead of retrying.
    public var canAccept: Bool {
        state == .reviewing && preview != nil && acceptingSession == nil && notice != .assemblyFailed
    }

    /// An Accept in progress makes Discard unavailable until it settles: a confirmed Discard never
    /// races an assembly that may already be opening an editor.
    public var canDiscard: Bool { state == .reviewing && acceptingSession == nil }

    /// The review is still drawing its preview.
    public var isPreparingPreview: Bool { state == .reviewing && preview == nil && notice != .assemblyFailed }

    // MARK: Commands

    /// Checks screen permission just in time and moves to target selection.
    @discardableResult
    public func begin() async -> Bool {
        guard state == .idle || !state.isActive else { return false }
        if state != .idle { apply(.reset) }
        // A step in flight when the last session ended may have left a scroller for its target.
        autoScroller?.stop()
        resetProgress()
        notice = nil
        let isGranted = screenPermission.isGranted
        diagnostics?.record(.permissionStatus(permission: .screenRecording, granted: isGranted))
        if !isGranted {
            let granted = await screenPermission.request()
            diagnostics?.record(.permissionStatus(permission: .screenRecording, granted: granted))
            guard granted else {
                notice = .screenPermissionDenied
                return false
            }
            guard state == .idle else { return false }
        }
        sessionID = UUID()
        apply(.begin)
        return true
    }

    public func chooseTarget(_ target: CaptureTarget) {
        guard state == .selecting else { return }
        self.target = target
        mode = .manual
        direction = settings.preferences.scrollCaptureDirection
        if settings.preferences.automaticScrollingEnabled {
            let isTrusted = accessibility.isTrusted
            diagnostics?.record(.permissionStatus(permission: .accessibility, granted: isTrusted))
            if isTrusted, autoScroller != nil {
                mode = .automatic
            } else {
                notice = .automaticNeedsAccessibility
            }
        }
        apply(.targetChosen)
    }

    /// Picks the scroll direction before Start and remembers it for the next session.
    public func chooseDirection(_ direction: ScrollCaptureDirection) {
        guard state == .armed else { return }
        self.direction = direction
        settings.update { $0.scrollCaptureDirection = direction }
    }

    public func start() {
        guard state == .armed, let target, let id = sessionID else { return }
        autoScroller?.stop()  // every session scrolls with a scroller made for its own target
        apply(.start)
        let started = clock.uptime()
        startedAt = started
        let deadline = started + Self.maxDuration
        task = Task { [weak self] in await self?.collect(target, id: id) }
        deadlineTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                let remaining = deadline - clock.uptime()
                if remaining <= .zero { break }
                do { try await clock.sleep(for: remaining) } catch { return }
            }
            guard !Task.isCancelled, clock.uptime() >= deadline else { return }
            self?.deadlineReached(id: id)
        }
    }

    /// Pauses appending. The stream keeps running; frames that arrive while paused are dropped.
    public func pause() {
        guard state == .collecting, pendingFinish == nil else { return }
        settleTask?.cancel()
        apply(.pause(.userPaused))
    }

    /// Resumes appending; in automatic mode Recortia scrolls again rather than waiting for the
    /// page to change by itself.
    public func resume() {
        guard isPausedState, pendingFinish == nil else { return }
        apply(.resume)
        guard mode == .automatic, let target, let id = sessionID else { return }
        unansweredSteps = 0
        settleTask?.cancel()
        settleTask = Task { [weak self] in await self?.autoStep(target, id: id) }
    }

    /// Ends collection and opens the review. Stopping while paused on an ambiguous match keeps
    /// that reason as the partial label.
    public func stop() {
        switch state {
        case .collecting:
            finishCollecting(partial: nil)
        case .paused(let reason):
            finishCollecting(partial: reason == .userPaused ? nil : .ambiguous(reason))
        default:
            break
        }
    }

    public func cancel() {
        guard state.isActive else { return }
        tearDown()
        apply(.cancel)
    }

    /// Discards the review, or an active capture; refused while an Accept assembles (`canDiscard`).
    public func discard() {
        guard acceptingSession == nil else { return }
        cancel()
    }

    /// Stops a session that is selecting or capturing at once, for events the app observes:
    /// screen lock, display reconfiguration, permission revocation, or target loss (FR-10, PERM-02).
    ///
    /// The stream and the auto scroller stop, every timer is released, the stitch is discarded,
    /// and the session fails with `failure`. Nothing captured is kept: the interruption was not
    /// the user's choice, the domain has no partial reason for it, and after a lock or a
    /// revocation the frames should not outlive the capture. A session already in review has
    /// nothing running and keeps its result for the user to accept or discard.
    public func interrupt(because failure: ScrollFailure) {
        switch state {
        case .selecting, .armed, .collecting, .paused:
            fail(failure)
        default:
            break
        }
    }

    /// Reported by the app when the target window or display went away.
    public func targetLost() {
        switch state {
        case .armed, .collecting, .paused:
            tearDown()
            apply(.targetLost)
        default:
            break
        }
    }

    public func accept() async {
        guard canAccept, let id = sessionID else { return }
        acceptingSession = id
        defer { if acceptingSession == id { acceptingSession = nil } }
        let reason = partialReason
        let image: CGImage
        let info: ImageAssetInfo
        do {
            image = try await stitcher.assemble()
            guard sessionID == id, state == .reviewing else { return }
            info = try await assets.registerStitched(
                image, partialReason: reason,
                pointPixelScale: Self.pointPixelScale(of: image, on: target, direction: direction))
        } catch {
            guard sessionID == id else { return }
            notice = .assemblyFailed
            return
        }
        guard sessionID == id, state == .reviewing else {
            assets.release(info.id)
            return
        }
        apply(.accept)
        stitcher.reset(direction: direction)
        preview = nil
        sessionID = nil
        let preferences = settings.preferences
        // A scrolling capture is a capture: it opens with the saved default framing.
        let document = Document(
            capture: info, windowBackground: .transparent, defaultFraming: preferences.defaultFraming)
        onAccepted?(DocumentSession(document: document), preferences.autoRedactsSensitiveText)
    }

    func clearNotice() { notice = nil }

    /// Pixels per point of the stitched image, measured across the scroll direction (its width, or
    /// its height when it scrolled sideways): every frame spans the target at its display's scale.
    /// A target the display clips measures lower, which only makes automatic masking's sweep slower
    /// (it upsamples more, FR-06); 1 when it cannot be measured.
    static func pointPixelScale(
        of image: CGImage, on target: CaptureTarget?, direction: ScrollCaptureDirection
    ) -> Double {
        let frame: Rect<DesktopSpace>? =
            switch target {
            case .region(let rect, _): rect
            case .display(let display): display.frame
            case .window(let window): window.frame
            case nil: nil
            }
        let horizontal = direction == .horizontal
        guard let frame else { return 1 }
        let points = horizontal ? frame.height : frame.width
        guard points > 0 else { return 1 }
        let scale = Double(horizontal ? image.height : image.width) / points
        return scale.isFinite ? max(1, scale) : 1
    }

    // MARK: Collection

    private func collect(_ target: CaptureTarget, id: UUID) async {
        // A cancel, stop, or interrupt can land before this task first runs; never start a stream
        // for a session that already ended, and stop one whose session ended while it started.
        guard isCurrent(id) else { return }
        do throws(CaptureError) {
            stitcher.reset(direction: direction)
            streamOwner = id
            try await frames.start(target)
            guard isCurrent(id) else {
                // A newer session's start replaced this stream; stopping now would stop that one.
                if streamOwner == id {
                    frames.stop()
                    streamOwner = nil
                }
                return
            }
            streamStarted = true
        } catch {
            guard isCurrent(id) else { return }
            handle(error)
            return
        }
        while isCurrent(id), state == .collecting || isPausedState {
            let frame: CGImage
            do throws(CaptureError) {
                frame = try await frames.nextFrame()
            } catch {
                guard isCurrent(id) else { return }
                handle(error)
                return
            }
            guard isCurrent(id) else { return }
            guard state == .collecting else { continue }  // paused: drop the frame, keep the stream

            settleTask?.cancel()  // a frame answered the last scroll step

            let elapsed = elapsedSinceStart()
            let lengthBefore = stitchedLength
            appendInFlight = true
            let result = await stitcher.append(frame, elapsed: elapsed)
            if sessionID == id { appendInFlight = false }  // a replacement session owns the flag now
            guard isCurrent(id) else { return }

            if case .accepted = result {
                if lengthBefore > 0 { seams.append(lengthBefore) }
                acceptedFrames = stitcher.acceptedFrameCount
                outputSize = stitcher.outputSize
            }
            if let finish = pendingFinish {
                // Stop landed during the append: its result is recorded above, so freeze now. A
                // rejected viewport is missing from the review, so its reason labels it partial.
                pendingFinish = nil
                var partial = finish.partial
                if partial == nil {
                    switch result {
                    case .ambiguous(let reason): partial = .ambiguous(reason)
                    case .limitReached(let limit): partial = .limit(limit)
                    case .accepted, .stationary: break
                    }
                }
                completeFinish(partial: partial, event: finish.event)
                return
            }

            switch result {
            case .accepted:
                unansweredSteps = 0
            case .stationary:
                break
            case .ambiguous(let reason):
                if state == .collecting { apply(.pause(reason)) }
                continue
            case .limitReached(let limit):
                finishCollecting(partial: .limit(limit), event: .limitReached(limit))
                return
            }
            // Paused while this frame was stitched: keep the loop (and the stream) for Resume.
            guard state == .collecting else { continue }

            if stitcher.endOfPageDetected {
                if mode == .automatic {
                    // Stationary frames are also what a stalled, lazy-loading page produces:
                    // complete only when the target confirms its scroll area is at its end.
                    let atEnd = await autoScroller?.isAtEnd(target, direction: direction)
                    guard isCurrent(id), state == .collecting, pendingFinish == nil, mode == .automatic else { return }
                    finishCollecting(partial: atEnd == true ? nil : .stoppedMoving)
                    return
                }
                pageEndLikely = true
            } else {
                pageEndLikely = false
            }
            if mode == .automatic { await autoStep(target, id: id) }
        }
    }

    /// Sends one scroll step and, once it was sent, waits `automaticSettleInterval` for a frame.
    /// Runs from the collection loop, the settle timer, or Resume; one step at a time.
    private func autoStep(_ target: CaptureTarget, id: UUID) async {
        guard isCurrent(id), state == .collecting, pendingFinish == nil, mode == .automatic, autoStepOwner != id
        else { return }
        guard accessibility.isTrusted, let autoScroller else {
            mode = .manual
            notice = .accessibilityRevoked
            return
        }
        autoStepOwner = id
        let step = await autoScroller.step(target, direction: direction)
        if autoStepOwner == id { autoStepOwner = nil }
        guard isCurrent(id), state == .collecting, pendingFinish == nil, mode == .automatic else { return }
        switch step {
        case .scrolled:
            settleTask?.cancel()
            settleTask = Task { [weak self, clock] in
                do { try await clock.sleep(for: Self.automaticSettleInterval) } catch { return }
                await self?.settleElapsed(target, id: id)
            }
        case .reachedEnd:
            finishCollecting(partial: nil)
        case .targetLost:
            targetLost()
        }
    }

    /// No frame answered the last scroll step: the page did not move.
    private func settleElapsed(_ target: CaptureTarget, id: UUID) async {
        guard isCurrent(id), state == .collecting, pendingFinish == nil, mode == .automatic else { return }
        unansweredSteps += 1
        if unansweredSteps >= ScrollStitcher.endOfPageStationaryFrames, stitcher.acceptedFrameCount > 0 {
            // No frame is also what a stalled, lazy-loading page looks like: complete only when
            // the target confirms its scroll area is at its end.
            let atEnd = await autoScroller?.isAtEnd(target, direction: direction)
            guard isCurrent(id), state == .collecting, pendingFinish == nil, mode == .automatic else { return }
            finishCollecting(partial: atEnd == true ? nil : .stoppedMoving)
            return
        }
        await autoStep(target, id: id)
    }

    /// The 2-minute limit, independent of frame arrival; paused time counts.
    private func deadlineReached(id: UUID) {
        guard sessionID == id else { return }
        switch state {
        case .collecting:
            finishCollecting(partial: .limit(.duration), event: .limitReached(.duration))
        case .paused:
            finishCollecting(partial: .limit(.duration))
        default:
            break
        }
    }

    private func finishCollecting(partial: ScrollPartialReason?, event: ScrollEvent = .stop) {
        guard pendingFinish == nil else { return }
        stopStream()
        cancelTimers()
        if appendInFlight {
            // Keep the collection task: it settles the admitted append, then calls `completeFinish`.
            pendingFinish = PendingFinish(partial: partial, event: event)
            return
        }
        completeFinish(partial: partial, event: event)
    }

    private func completeFinish(partial: ScrollPartialReason?, event: ScrollEvent) {
        task?.cancel()
        task = nil
        pageEndLikely = false
        partialReason = partial
        apply(event)
        guard stitcher.acceptedFrameCount > 0 else {
            partialReason = nil
            stitcher.reset(direction: direction)
            apply(.fail(.noFrames))
            diagnostics?.record(.scrollCaptureFailed(failure: .noFrames, frames: 0))
            sessionID = nil
            return
        }
        acceptedFrames = stitcher.acceptedFrameCount
        diagnostics?.record(
            .scrollCaptureFinished(
                frames: acceptedFrames, automatic: mode == .automatic, partial: partial != nil,
                duration: elapsedSinceStart()))
        outputSize = stitcher.outputSize
        guard let id = sessionID else { return }
        task = Task { [weak self] in
            guard let self else { return }
            let image = await self.stitcher.preview(maxLength: Self.previewMaxLength)
            guard self.sessionID == id, self.state == .reviewing else { return }
            // No preview means the stitch cannot be drawn within its budget: say so, rather than
            // leave the review waiting with Accept unavailable.
            guard let image else {
                self.notice = .assemblyFailed
                return
            }
            self.preview = image
        }
    }

    private func handle(_ error: CaptureError) {
        switch error {
        case .canceled:
            // Our own cancellation is filtered by isCurrent before this handler. A current
            // stream can also be stopped through macOS's screen-sharing controls.
            cancel()
        case .targetUnavailable, .system:
            targetLost()
        case .permissionDenied:
            fail(.permissionRevoked)
        case .displayChanged:
            fail(.displayChanged)
        }
    }

    private func fail(_ failure: ScrollFailure) {
        guard state.isActive else { return }
        diagnostics?.record(
            .scrollCaptureFailed(failure: DiagnosticScrollFailure(failure), frames: stitcher.acceptedFrameCount))
        tearDown()
        apply(.fail(failure))
    }

    // MARK: Bookkeeping

    private func tearDown() {
        pendingFinish = nil
        appendInFlight = false
        cancelTimers()
        task?.cancel()
        task = nil
        stopStream()
        stitcher.reset(direction: direction)
        resetProgress()
        sessionID = nil
    }

    private func cancelTimers() {
        deadlineTask?.cancel()
        deadlineTask = nil
        settleTask?.cancel()
        settleTask = nil
        unansweredSteps = 0
    }

    private func stopStream() {
        autoScroller?.stop()
        if streamStarted || state == .collecting || isPausedState {
            frames.stop()
            streamStarted = false
        }
    }

    private var isPausedState: Bool {
        if case .paused = state { return true }
        return false
    }

    private func resetProgress() {
        pendingFinish = nil
        acceptingSession = nil
        appendInFlight = false
        acceptedFrames = 0
        outputSize = PixelSize(width: 0, height: 0)
        seams = []
        partialReason = nil
        preview = nil
        pageEndLikely = false
        startedAt = nil
    }

    /// The stitch's length along the scroll direction.
    private var stitchedLength: Int {
        direction == .horizontal ? stitcher.outputSize.width : stitcher.outputSize.height
    }

    private func elapsedSinceStart() -> Duration {
        guard let startedAt else { return .zero }
        return max(.zero, clock.uptime() - startedAt)
    }

    private func isCurrent(_ id: UUID) -> Bool {
        sessionID == id && !Task.isCancelled
    }

    private func apply(_ event: ScrollEvent) {
        do {
            state = try state.next(event)
        } catch {
            assertionFailure("\(error)")
        }
    }
}
