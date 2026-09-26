#if DEBUG
    import CryptoKit
    import AppKit
    import Domain
    import Features
    import MacPlatform

    // DEBUG-only replacements for the boundaries that would need TCC, real input, or the user's
    // clipboard. Every other service in the E2E run is the live one from `AppServices.live()`.

    /// Returns crops of the generated synthetic desktop with a correct `CaptureGeometry`.
    /// Never calls ScreenCaptureKit and never reads the real screen.
    final class SyntheticCaptureService: CaptureService {
        let display: DisplayInfo
        let windowList: [WindowInfo]
        private let desktop: CGImage
        /// Delay before `windows()` returns, so the chooser's loading state is observable.
        var windowsDelay: Duration = .milliseconds(400)
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
                pixelSize: PixelSize(width: image.width, height: image.height), capturedAt: Date())
            return (image, geometry)
        }
    }

    /// Screen Recording reported as granted; counts requests so scenarios can assert none happened.
    final class SyntheticScreenPermission: ScreenPermissionService {
        private(set) var requestCount = 0
        var isGranted: Bool { true }

        func request() async -> Bool {
            requestCount += 1
            return true
        }
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

        /// Lets a held feed continue.
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
#endif
