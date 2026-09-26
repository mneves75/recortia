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
/// Manual scrolling always works. Automatic scrolling runs only when the user enabled it and the
/// process is trusted for Accessibility; otherwise the session explains why and stays manual.
/// Ambiguous matches pause instead of appending, a reached limit ends collection into review
/// with a partial reason, and target loss, display change, or permission revocation stop the
/// stream immediately. Frames that arrive after Stop or Cancel are dropped.
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

    public static let previewMaxHeight = 2_000

    public private(set) var state: ScrollState = .idle
    public private(set) var mode: ScrollMode = .manual
    public private(set) var notice: Notice?
    public private(set) var target: CaptureTarget?
    public private(set) var acceptedFrames = 0
    public private(set) var outputSize = PixelSize(width: 0, height: 0)
    /// Output rows where one accepted frame joins the next, for the review's seam markers.
    public private(set) var seams: [Int] = []
    public private(set) var partialReason: ScrollPartialReason?
    public private(set) var preview: CGImage?

    @ObservationIgnored public var onAccepted: ((DocumentSession) -> Void)?

    @ObservationIgnored private let frames: any ScrollFrameSourceService
    @ObservationIgnored private let stitcher: any ScrollStitchService
    @ObservationIgnored private let autoScroller: (any AutoScrollService)?
    @ObservationIgnored private let accessibility: any AccessibilityPermissionService
    @ObservationIgnored private let screenPermission: any ScreenPermissionService
    @ObservationIgnored private let assets: any ImageAssetService
    @ObservationIgnored private let clock: any FeatureClock
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var streamStarted = false
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(
        frames: any ScrollFrameSourceService, stitcher: any ScrollStitchService, autoScroller: (any AutoScrollService)?,
        accessibility: any AccessibilityPermissionService, screenPermission: any ScreenPermissionService,
        assets: any ImageAssetService, clock: any FeatureClock, settings: SettingsStore
    ) {
        self.frames = frames
        self.stitcher = stitcher
        self.autoScroller = autoScroller
        self.accessibility = accessibility
        self.screenPermission = screenPermission
        self.assets = assets
        self.clock = clock
        self.settings = settings
    }

    public var isPartial: Bool { partialReason != nil }

    // MARK: Commands

    /// Checks screen permission just in time and moves to target selection.
    @discardableResult
    public func begin() async -> Bool {
        guard state == .idle || !state.isActive else { return false }
        if state != .idle { apply(.reset) }
        resetProgress()
        notice = nil
        if !screenPermission.isGranted {
            let granted = await screenPermission.request()
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
        if settings.preferences.automaticScrollingEnabled {
            if accessibility.isTrusted, autoScroller != nil {
                mode = .automatic
            } else {
                notice = .automaticNeedsAccessibility
            }
        }
        apply(.targetChosen)
    }

    public func start() {
        guard state == .armed, let target, let id = sessionID else { return }
        apply(.start)
        startedAt = clock.now()
        task = Task { [weak self] in await self?.collect(target, id: id) }
    }

    /// Pauses appending. The stream keeps running; frames that arrive while paused are dropped.
    public func pause() {
        guard state == .collecting else { return }
        apply(.pause(.userPaused))
    }

    public func resume() {
        guard isPausedState else { return }
        apply(.resume)
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

    public func discard() { cancel() }

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
        guard state == .reviewing, let id = sessionID else { return }
        let reason = partialReason
        let image: CGImage
        let info: ImageAssetInfo
        do {
            image = try await stitcher.assemble()
            guard sessionID == id, state == .reviewing else { return }
            info = try await assets.registerStitched(image, partialReason: reason)
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
        stitcher.reset()
        preview = nil
        sessionID = nil
        onAccepted?(DocumentSession(document: Document(asset: info)))
    }

    public func clearNotice() { notice = nil }

    // MARK: Collection

    private func collect(_ target: CaptureTarget, id: UUID) async {
        do throws(CaptureError) {
            stitcher.reset()
            try await frames.start(target)
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

            let elapsed = elapsedSinceStart()
            let heightBefore = stitcher.outputSize.height
            let result = await stitcher.append(frame, elapsed: elapsed)
            guard isCurrent(id), state == .collecting else { return }

            switch result {
            case .accepted:
                if heightBefore > 0 { seams.append(heightBefore) }
                acceptedFrames = stitcher.acceptedFrameCount
                outputSize = stitcher.outputSize
            case .stationary:
                break
            case .ambiguous(let reason):
                apply(.pause(reason))
                continue
            case .limitReached(let limit):
                finishCollecting(partial: .limit(limit), event: .limitReached(limit))
                return
            }

            if mode == .automatic {
                guard accessibility.isTrusted, let autoScroller else {
                    mode = .manual
                    notice = .accessibilityRevoked
                    continue
                }
                let step = await autoScroller.step(target)
                guard isCurrent(id), state == .collecting else { return }
                switch step {
                case .scrolled:
                    break
                case .reachedEnd:
                    finishCollecting(partial: nil)
                    return
                case .targetLost:
                    targetLost()
                    return
                }
            }
        }
    }

    private func finishCollecting(partial: ScrollPartialReason?, event: ScrollEvent = .stop) {
        stopStream()
        task?.cancel()
        task = nil
        partialReason = partial
        apply(event)
        guard stitcher.acceptedFrameCount > 0 else {
            partialReason = nil
            stitcher.reset()
            apply(.fail(.noFrames))
            sessionID = nil
            return
        }
        acceptedFrames = stitcher.acceptedFrameCount
        outputSize = stitcher.outputSize
        guard let id = sessionID else { return }
        task = Task { [weak self] in
            guard let self else { return }
            let image = await self.stitcher.preview(maxHeight: Self.previewMaxHeight)
            guard self.sessionID == id, self.state == .reviewing else { return }
            self.preview = image
        }
    }

    private func handle(_ error: CaptureError) {
        switch error {
        case .canceled:
            return  // our own stop/cancel; the state already moved
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
        tearDown()
        apply(.fail(failure))
    }

    // MARK: Bookkeeping

    private func tearDown() {
        task?.cancel()
        task = nil
        stopStream()
        stitcher.reset()
        resetProgress()
        sessionID = nil
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
        acceptedFrames = 0
        outputSize = PixelSize(width: 0, height: 0)
        seams = []
        partialReason = nil
        preview = nil
        startedAt = nil
    }

    private func elapsedSinceStart() -> Duration {
        guard let startedAt else { return .zero }
        let seconds = max(0, clock.now().timeIntervalSince(startedAt))
        return .milliseconds(Int64((seconds * 1000).rounded()))
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
