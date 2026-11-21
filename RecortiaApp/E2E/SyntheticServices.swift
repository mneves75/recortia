#if DEBUG
    import CryptoKit
    import AppKit
    import Domain
    import Features
    import MacPlatform

    // DEBUG-only replacements for the boundaries that would need TCC, real input, or the user's
    // clipboard. Every other service in the E2E run is the live one from `AppServices.live()`.

    /// Stands in for Sparkle (FP-024): scripted results, no network, no updater window.
    @MainActor
    final class SyntheticUpdateService: UpdateService {
        var result = UpdateCheckResult.noUpdate
        private(set) var starts: [Bool] = []
        private(set) var automatic: [Bool] = []
        private(set) var checks = 0
        private(set) var installs = 0

        func start(checksAutomatically: Bool) -> UpdaterStart {
            starts.append(checksAutomatically)
            return .started
        }

        func setChecksAutomatically(_ enabled: Bool) { automatic.append(enabled) }

        func checkForUpdates() async -> UpdateCheckResult {
            checks += 1
            return result
        }

        func installUpdate() { installs += 1 }
    }

    /// Records automatic-scroll steps instead of posting events. The E2E run grants Accessibility
    /// synthetically, so the live scroller would drive whatever window a target names, possibly one
    /// of the host Mac's own. No scenario needs a real scroll: frames come from
    /// `SyntheticScrollFrames`, and the scroller's binding rules are covered by
    /// `AutoScrollRegression` with its recording driver.
    @MainActor
    final class SyntheticAutoScroll: AutoScrollService {
        private(set) var steppedTargets: [CaptureTarget] = []
        private(set) var stepDirections: [ScrollCaptureDirection] = []
        private(set) var stopCount = 0
        var atEnd: Bool?

        func step(_ target: CaptureTarget, direction: ScrollCaptureDirection) async -> AutoScrollStep {
            steppedTargets.append(target)
            stepDirections.append(direction)
            return .scrolled
        }

        func stop() { stopCount += 1 }

        func isAtEnd(_ target: CaptureTarget, direction: ScrollCaptureDirection) async -> Bool? { atEnd }
    }

    /// Returns crops of the generated synthetic desktop with a correct `CaptureGeometry`.
    /// Never calls ScreenCaptureKit and never reads the real screen.
    final class SyntheticCaptureService: CaptureService {
        let display: DisplayInfo
        let windowList: [WindowInfo]
        private let desktop: CGImage
        /// Delay before `windows()` returns, so the chooser's loading state is observable.
        var windowsDelay: Duration = .milliseconds(400)
        var fixedCaptureDate: Date?
        private(set) var captures: [CaptureTarget] = []

        init(desktop: CGImage) {
            // The main display's ID (an identifier only; its pixels are never read) lets the UI name
            // the display; the frame and scale are the synthetic desktop's own.
            display = DisplayInfo(
                id: CGMainDisplayID(),
                frame: Rect(x: 0, y: 0, width: SyntheticDesktop.size.width, height: SyntheticDesktop.size.height),
                pointPixelScale: SyntheticDesktop.scale, fingerprint: "synthetic-1280x800@2")
            self.desktop = desktop
            let notes = SyntheticDesktop.notesWindow, terminal = SyntheticDesktop.terminalWindow
            windowList = [
                WindowInfo(
                    id: 9_101, ownerName: "Synthetic Notes", ownerPID: 0, title: "Quarterly report",
                    frame: Rect(x: notes.minX, y: notes.minY, width: notes.width, height: notes.height),
                    displayID: display.id),
                WindowInfo(
                    id: 9_102, ownerName: "Synthetic Terminal", ownerPID: 0, title: "build",
                    frame: Rect(x: terminal.minX, y: terminal.minY, width: terminal.width, height: terminal.height),
                    displayID: display.id),
                WindowInfo(
                    id: 9_103, ownerName: "Synthetic Preview", ownerPID: 0, title: nil,
                    frame: Rect(x: 40, y: 600, width: 300, height: 160), displayID: display.id),
            ]
        }

        func displays() -> [DisplayInfo] { [display] }

        func windows() async throws(CaptureError) -> [WindowInfo] {
            try? await Task.sleep(for: windowsDelay)
            return windowList
        }

        func capture(_ target: CaptureTarget, showsCursor: Bool, includesShadow: Bool) async throws(CaptureError)
            -> (CGImage, CaptureGeometry)
        {
            captures.append(target)
            let bounds: Rect<DesktopSpace>
            let source: CaptureSource
            switch target {
            case .region(let rect, let display):
                guard display.id == self.display.id else { throw .targetUnavailable }
                bounds = rect
                source = .region(displayID: display.id)
            case .display(let display):
                guard display.id == self.display.id else { throw .targetUnavailable }
                bounds = display.frame
                source = .display(id: display.id)
            case .window(let window):
                guard windowList.contains(window) else { throw .targetUnavailable }
                bounds = window.frame
                source = .window(id: window.id, displayID: window.displayID)
            }
            guard let clipped = bounds.intersection(display.frame) else { throw .targetUnavailable }
            let scale = display.pointPixelScale
            let pixels = CGRect(
                x: (clipped.minX * scale).rounded(.down), y: (clipped.minY * scale).rounded(.down),
                width: (clipped.width * scale).rounded(.up), height: (clipped.height * scale).rounded(.up))
            guard let image = desktop.cropping(to: pixels) else { throw .system(code: -1) }
            let geometry = CaptureGeometry(
                source: source, desktopBounds: clipped, pointPixelScale: scale,
                pixelSize: PixelSize(width: image.width, height: image.height), capturedAt: fixedCaptureDate ?? Date())
            return (image, geometry)
        }
    }

    /// Screen Recording reported as granted; counts requests so scenarios can assert none happened.
    final class SyntheticScreenPermission: ScreenPermissionService {
        private(set) var requestCount = 0
        var isGranted = true
        var holdRequest = false
        private var waiter: CheckedContinuation<Bool, Never>?

        func request() async -> Bool {
            requestCount += 1
            if holdRequest {
                return await withCheckedContinuation { waiter = $0 }
            }
            return isGranted
        }

        func finishRequest(granted: Bool) {
            isGranted = granted
            holdRequest = false
            let continuation = waiter
            waiter = nil
            continuation?.resume(returning: granted)
        }
    }

    final class SyntheticAccessibilityPermission: AccessibilityPermissionService {
        var isTrusted = true
        private(set) var requestCount = 0

        func requestWithPrompt() { requestCount += 1 }
    }

    /// Element frames for region snapping (B-7) from a synthetic interface tree of the first listed
    /// window's app, walked by the product's `ElementSnapping.walk`. It never calls Accessibility:
    /// trust is the harness's synthetic flag, and like the live service it has no prompt path.
    /// `holds` keeps each read waiting until `releaseOldest()`, so a scenario can end the selection
    /// first.
    final class SyntheticInterfaceElements: InterfaceElementFrameService {
        /// A button inside the synthetic notes window, away from every window edge.
        static let button = Rect<DesktopSpace>(x: 520, y: 300, width: 80, height: 30)
        /// The toolbar, sidebar, content area and button; the tree also holds one element too small
        /// and one off the display, which the overlay must not snap to.
        static let admittedCount = 4

        private let accessibility: SyntheticAccessibilityPermission
        var holds = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var readCount = 0
        var waitingCount: Int { waiters.count }

        init(accessibility: SyntheticAccessibilityPermission) {
            self.accessibility = accessibility
        }

        func frames(under windows: [WindowInfo]) async -> ElementSnapping.Walk? {
            guard accessibility.isTrusted, let window = windows.first else { return nil }
            readCount += 1
            if holds { await withCheckedContinuation { waiters.append($0) } }
            return ElementSnapping.walk(from: Self.tree(in: window.frame)) { .zero }
        }

        func releaseOldest() {
            guard !waiters.isEmpty else { return }
            waiters.removeFirst().resume()
        }

        func releaseAll() {
            while !waiters.isEmpty { releaseOldest() }
        }

        private static func tree(in window: Rect<DesktopSpace>) -> SyntheticElementNode {
            func element(_ frame: Rect<DesktopSpace>, _ children: [SyntheticElementNode] = []) -> SyntheticElementNode {
                SyntheticElementNode(reading: InterfaceElementReading(frame: frame, kind: .element), nodes: children)
            }
            let toolbar = element(Rect(x: window.minX, y: window.minY, width: window.width, height: 32))
            let sidebar = element(Rect(x: window.minX, y: window.minY + 32, width: 160, height: window.height - 32))
            let content = element(
                Rect(x: window.minX + 160, y: window.minY + 32, width: window.width - 160, height: window.height - 32),
                [element(button), element(Rect(x: 700, y: 400, width: 4, height: 4))])
            // Off the synthetic display altogether.
            let offscreen = element(Rect(x: 4_000, y: 300, width: 80, height: 30))
            let windowNode = SyntheticElementNode(
                reading: InterfaceElementReading(frame: window, kind: .container),
                nodes: [toolbar, sidebar, content, offscreen])
            return SyntheticElementNode(
                reading: InterfaceElementReading(frame: nil, kind: .container), nodes: [windowNode])
        }
    }

    struct SyntheticElementNode: InterfaceElementNode {
        let reading: InterfaceElementReading
        let nodes: [SyntheticElementNode]

        func read() -> InterfaceElementReading? { reading }
        func children(limit: Int) -> [SyntheticElementNode] { Array(nodes.prefix(limit)) }
    }

    /// Feeds pre-rendered viewport frames of a RecortiaFixtures long page. `holdAfter` pauses the
    /// feed after that many frames until `release()`, so the HUD can be captured mid-collection.
    final class SyntheticScrollFrames: ScrollFrameSourceService {
        private var frames: [CGImage] = []
        private var index = 0
        private var holdAfter: Int?
        private var waiter: CheckedContinuation<Void, Never>?
        private var isRunning = false
        private(set) var startCount = 0
        private(set) var stopCount = 0

        var deliveredCount: Int { index }
        var isExhausted: Bool { index >= frames.count }
        var isHolding: Bool { waiter != nil }

        func load(_ frames: [CGImage], holdAfter: Int?) {
            self.frames = frames
            self.holdAfter = holdAfter
            index = 0
        }

        func start(_ target: CaptureTarget) async throws(CaptureError) {
            startCount += 1
            isRunning = true
        }

        func nextFrame() async throws(CaptureError) -> CGImage {
            while isRunning, index >= frames.count || index == holdAfter {
                await withCheckedContinuation { waiter = $0 }
            }
            guard isRunning else { throw .canceled }
            let frame = frames[index]
            index += 1
            return frame
        }

        func release() {
            holdAfter = nil
            resumeWaiter()
        }

        func stop() {
            guard isRunning else { return }
            stopCount += 1
            isRunning = false
            resumeWaiter()
        }

        private func resumeWaiter() {
            let continuation = waiter
            waiter = nil
            continuation?.resume()
        }
    }

    /// The live `ClipboardSink` pointed at a private named pasteboard, never `.general`.
    final class PrivatePasteboardClipboard: ClipboardSinkService {
        let pasteboard: NSPasteboard
        private(set) var writeCount = 0

        init(pasteboard: NSPasteboard) {
            self.pasteboard = pasteboard
        }

        func write(_ snapshot: ShareSnapshot) throws(SinkError) {
            try ClipboardSink(pasteboard: pasteboard).write(snapshot)
            writeCount += 1
        }
    }

    /// Stands in for the print panel (B-9a): builds the real print operation for each snapshot and
    /// records it, but never runs it, so no panel, printer or PDF is touched.
    final class RecordingPrinter: PrintSinkService {
        private(set) var snapshots: [ShareSnapshot] = []
        private(set) var operations: [NSPrintOperation] = []

        func present(_ snapshot: ShareSnapshot) throws(SinkError) {
            let operation = try PrintSink.operation(for: snapshot)
            snapshots.append(snapshot)
            operations.append(operation)
        }
    }

    /// Stands in for a receiving app: builds the real drag chip panel (never shown), then fulfils
    /// the real `DragOutProvider` file promise into a folder under the output directory.
    final class SyntheticDragReceiver: DragSinkService {
        let dropFolder: URL
        private(set) var panel: DragChipPanel?
        private(set) var deliveredFiles: [URL] = []

        init(dropFolder: URL) {
            self.dropFolder = dropFolder
        }

        func deliver(_ snapshot: ShareSnapshot, lease: ExportLease) async throws(SinkError) -> DragDeliveryOutcome {
            guard !lease.isRevoked else { return .canceledByUser }
            guard let image = NSImage(data: snapshot.bytes) else { throw .writeFailed(code: Int(EINVAL)) }
            let chip = DragChipPanel(snapshot: snapshot, lease: lease, image: image) { _ in }
            E2ESnapshot.park(chip)
            panel = chip
            let provider = DragOutProvider(snapshot: snapshot, lease: lease)
            let promise = provider.makeFilePromiseProvider()
            let name = provider.filePromiseProvider(promise, fileNameForType: snapshot.format.utTypeIdentifier)
            let destination = dropFolder.appending(path: name)
            let failed: Bool = await withCheckedContinuation { continuation in
                provider.filePromiseProvider(promise, writePromiseTo: destination) { error in
                    continuation.resume(returning: error != nil)
                }
            }
            guard !failed else { throw .writeFailed(code: Int(EIO)) }
            deliveredFiles.append(destination)
            return .delivered
        }

        func dismiss() {
            panel?.close()
            panel = nil
        }
    }

    /// Records link requests and opens nothing.
    final class RecordingLinkOpener: ExternalLinkOpenerService {
        private(set) var requests: [URL] = []

        func open(_ url: URL) -> Bool {
            requests.append(url)
            return false
        }
    }

    extension SettingsStore {
        /// The only settings store the E2E run builds: in memory, never the user's defaults.
        /// Never the keychain-backed integrity: an E2E run must not create keychain items.
        static func e2eInMemory() -> SettingsStore {
            SettingsStore(storage: E2EPreferenceStorage(), integrity: E2EPreferenceIntegrity())
        }
    }

    /// HMAC under a key that lives only for this run.
    final class E2EPreferenceIntegrity: PreferenceIntegrityService {
        private let key = SymmetricKey(size: .bits256)

        func seal(_ data: Data) -> Data? { Data(HMAC<SHA256>.authenticationCode(for: data, using: key)) }

        func verify(_ data: Data, seal: Data) -> Bool {
            HMAC<SHA256>.isValidAuthenticationCode(seal, authenticating: data, using: key)
        }
    }

    /// In-memory preferences, so the run never reads or writes the user's settings.
    final class E2EPreferenceStorage: PreferenceStorage {
        private var values: [String: Data] = [:]

        func preferenceData(forKey key: String) -> Data? { values[key] }

        func setPreferenceData(_ data: Data?, forKey key: String) { values[key] = data }
    }

    /// The runner's clock: system time, except that it stands still while a scripted service holds.
    /// A held detection lasts as long as the scenario's screenshots, so without this a loaded Mac
    /// can run past the app's masking deadline before the scenario releases it.
    @MainActor
    final class E2EClock: FeatureClock {
        private let system = SystemClock()
        private var heldSince: ContinuousClock.Instant?
        private var heldTotal = Duration.zero
        /// Time a scenario skipped with `advance(by:)`.
        private var skipped = Duration.zero

        func now() -> Date { Date() }

        func uptime() -> Duration {
            let held = heldTotal + (heldSince.map { .now - $0 } ?? .zero)
            return system.uptime() - held + skipped
        }

        /// Sleeps in slices of at most 100 ms, so a skip ends a long sleep within one slice.
        func sleep(for duration: Duration) async throws {
            let end = uptime() + duration
            while true {
                let remaining = end - uptime()
                if remaining <= .zero { return }
                try await Task.sleep(for: heldSince == nil ? min(remaining, .milliseconds(100)) : .milliseconds(20))
            }
        }

        /// Moves app time forward without waiting, for deadlines too long to wait out (the
        /// 10-minute Reopen Closed Capture lifetime). Time never goes back.
        func advance(by duration: Duration) {
            skipped += max(.zero, duration)
        }

        func hold() {
            if heldSince == nil { heldSince = .now }
        }

        func resume() {
            guard let heldSince else { return }
            heldTotal += .now - heldSince
            self.heldSince = nil
        }
    }

    /// Scripted automatic-masking detection (FR-06) and text-line recognition (A-6): returns the
    /// regions or lines a scenario sets, can hold until released, or fail. It reads no pixels and never runs Vision. While it holds, `clock`
    /// stands still, so app deadlines measure the app's time rather than the scenario's.
    @MainActor
    final class SyntheticSensitiveText: SensitiveTextService {
        struct Failure: Error {}

        let clock: E2EClock
        init(clock: E2EClock) { self.clock = clock }

        var regions: [PixelRect] = []
        var lines: [PixelRect] = []
        var fails = false
        var holds = false
        private var waiter: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { waiter != nil }
        private(set) var requestCount = 0
        private(set) var lineAreas: [PixelRect] = []

        func sensitiveRegions(in asset: ImageAssetInfo) async throws -> [PixelRect] {
            requestCount += 1
            return try await answer(regions)
        }

        func textLineRegions(
            in asset: ImageAssetInfo, within area: PixelRect, hiding hidden: [PixelRect]
        ) async throws -> [PixelRect] {
            lineAreas.append(area)
            return try await answer(lines)
        }

        private func answer(_ result: [PixelRect]) async throws -> [PixelRect] {
            if holds {
                clock.hold()
                await withCheckedContinuation { waiter = $0 }
            }
            try Task.checkCancellation()
            if fails { throw Failure() }
            return result
        }

        func release() {
            clock.resume()
            waiter?.resume()
            waiter = nil
        }

        func reset() {
            release()
            regions = []
            lines = []
            lineAreas = []
            fails = false
            holds = false
        }
    }
#endif
