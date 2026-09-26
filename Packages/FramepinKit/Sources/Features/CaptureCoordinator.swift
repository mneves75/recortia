import CoreGraphics
import Domain
import Foundation
import MacPlatform
import Observation

public enum CapturePurpose: Hashable, Sendable {
    /// Open the capture in the editor.
    case edit
    /// Recognize text in the captured region (Capture Text).
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

    /// Size of `rect` in the display's actual pixels (never an assumed 2x).
    public static func pixelSize(of rect: Rect<DesktopSpace>, on display: DisplayInfo) -> PixelSize {
        let scale = display.pointPixelScale.isFinite && display.pointPixelScale > 0 ? display.pointPixelScale : 1
        let width = (rect.width * scale).rounded(), height = (rect.height * scale).rounded()
        guard width.isFinite, height.isFinite, width < Double(Int32.max), height < Double(Int32.max) else {
            return PixelSize(width: 0, height: 0)
        }
        return PixelSize(width: max(0, Int(width)), height: max(0, Int(height)))
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
        /// The remembered region's display changed or disappeared; a new selection is needed.
        case repeatRegionUnavailable
    }

    /// Delay used by Capture with Delay when the preference is 0 seconds.
    public static let fallbackDelaySeconds = 5

    public private(set) var state: CaptureState = .idle
    public private(set) var mode: CaptureMode?
    public private(set) var purpose: CapturePurpose = .edit
    public private(set) var selectionContext: SelectionContext?
    public private(set) var notice: Notice?
    public private(set) var lastSelectionWasClamped = false
    private var repeatRegion: RepeatRegion?

    @ObservationIgnored public var onCaptured: ((CaptureCompletion) -> Void)?

    @ObservationIgnored private let capture: any CaptureService
    @ObservationIgnored private let permission: any ScreenPermissionService
    @ObservationIgnored private let assets: any ImageAssetService
    @ObservationIgnored private let clock: any FeatureClock
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var active: ActiveCapture?
    @ObservationIgnored private var task: Task<Void, Never>?

    private struct ActiveCapture {
        let id: RequestID
        let delaySeconds: Int
    }

    /// Session-only memory for Repeat Last Region, bound to the display's identity and configuration.
    private struct RepeatRegion {
        let rect: Rect<DesktopSpace>
        let displayID: CGDirectDisplayID
        let fingerprint: String
    }

    public init(
        capture: any CaptureService, permission: any ScreenPermissionService, assets: any ImageAssetService,
        clock: any FeatureClock, settings: SettingsStore
    ) {
        self.capture = capture
        self.permission = permission
        self.assets = assets
        self.clock = clock
        self.settings = settings
    }

    public var hasRepeatRegion: Bool { repeatRegion != nil }

    public var delayForDelayedCapture: Int {
        let configured = settings.preferences.captureDelaySeconds
        return configured > 0 ? configured : Self.fallbackDelaySeconds
    }

    // MARK: Commands

    @discardableResult
    public func start(_ mode: CaptureMode, delaySeconds: Int = 0, purpose: CapturePurpose = .edit) -> StartResult {
        if state == .capturing {
            notice = .captureInProgress
            return .ignoredCaptureInProgress
        }
        let replaced = state.isActive
        if replaced { abortActive() }
        if !state.isActive, state != .idle { apply(.reset) }

        let id = RequestID()
        active = ActiveCapture(id: id, delaySeconds: CaptureRequest.clampedDelay(delaySeconds))
        self.mode = mode
        self.purpose = purpose
        notice = nil
        lastSelectionWasClamped = false
        apply(.request)

        if permission.isGranted {
            beginSelection(id)
        } else {
            task = Task { [weak self] in
                guard let self else { return }
                let granted = await self.permission.request()
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
        guard state == .selecting, let active else { return false }
        selectionContext = nil
        apply(.selectionCommitted(delaySeconds: active.delaySeconds))
        let id = active.id
        task = Task { [weak self] in await self?.run(target, id: id) }
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

    public func clearNotice() { notice = nil }

    // MARK: Flow

    private func beginSelection(_ id: RequestID) {
        apply(.permissionGranted)
        switch mode {
        case .region, nil:
            selectionContext = .region(capture.displays())
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
        let captured: (CGImage, CaptureGeometry)
        do throws(CaptureError) {
            captured = try await capture.capture(
                target, showsCursor: preferences.captureShowsCursor,
                includesShadow: preferences.captureIncludesWindowShadow)
        } catch {
            guard isCurrent(id) else { return }
            handle(error)
            return
        }
        guard isCurrent(id) else { return }

        let info: ImageAssetInfo
        do {
            info = try await assets.registerCapture(captured.0, geometry: captured.1)
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

        if case .region(let rect, let display) = target {
            repeatRegion = RepeatRegion(rect: rect, displayID: display.id, fingerprint: display.fingerprint)
        }
        let completion = CaptureCompletion(
            requestID: id, session: DocumentSession(document: Document(asset: info)), purpose: purpose)
        apply(.captureSucceeded)
        finish()
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

    private func abortActive() {
        task?.cancel()
        task = nil
        active = nil
        selectionContext = nil
        apply(.cancel)
    }

    private func finish() {
        active = nil
        task = nil
        selectionContext = nil
    }

    private func apply(_ event: CaptureEvent) {
        do {
            state = try state.next(event)
        } catch {
            // An illegal transition is a programming error; keep the last valid state.
            assertionFailure("\(error)")
        }
    }
}
