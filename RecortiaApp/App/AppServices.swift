import CoreGraphics
import Domain
import Features
import Foundation
import Imaging
import MacPlatform

/// The services the feature models use. `live(settings:)` builds the production set from the
/// Imaging and MacPlatform modules; E2E and previews substitute their own.
struct AppServices {
    var githubUpload: (any GitHubUploadService)? = nil
    var githubCredentials: (any GitHubCredentialService)? = nil
    let capture: any CaptureService
    let screenPermission: any ScreenPermissionService
    let accessibility: any AccessibilityPermissionService
    let assets: any ImageAssetService
    let input: any ImageInputService
    let renderer: any RenderService
    let exporter: any ExportService
    let clipboard: any ClipboardSinkService
    let files: any FileSinkService
    let drag: any DragSinkService
    let folders: any SaveFolderService
    let textRecognition: any TextRecognitionService
    let qrDecoder: any QRDecodingService
    let sensitiveText: any SensitiveTextService
    let scrollFrames: any ScrollFrameSourceService
    let stitcher: any ScrollStitchService
    /// Nil when automatic scrolling is not built; manual scrolling still works.
    let autoScroller: (any AutoScrollService)?
    let loginItem: any LoginItemService
    let clock: any FeatureClock
    /// Nil in the E2E runner and previews, which play no sound.
    var captureSound: (any CaptureSoundService)? = nil
    /// Element frames for region snapping (ADR-010); synthetic in the E2E runner, nil in previews.
    var interfaceElements: (any InterfaceElementFrameService)? = nil
    /// The optional diagnostics file (B-10); a run folder in the E2E runner, nil in previews.
    var diagnosticsLog: DiagnosticsLog? = nil
}

extension DiagnosticVersions {
    /// This build's version and build numbers and the running macOS version.
    static var current: DiagnosticVersions {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticVersions(
            app: DiagnosticVersion(parsing: info?["CFBundleShortVersionString"] as? String ?? ""),
            build: Int(info?["CFBundleVersion"] as? String ?? "") ?? 0,
            macOS: DiagnosticVersion(major: os.majorVersion, minor: os.minorVersion, patch: os.patchVersion))
    }
}

final class SystemClock: FeatureClock {
    func now() -> Date { Date() }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Holds the value-type stitcher in an actor so frame matching runs off the main actor.
private actor StitchEngine {
    private var stitcher = ScrollStitcher()

    func reset() { stitcher = ScrollStitcher() }

    func append(_ frame: CGImage, elapsed: Duration) -> (ScrollAppendResult, Int, PixelSize, Bool) {
        let result = stitcher.append(frame, elapsed: elapsed)
        return (result, stitcher.acceptedFrameCount, stitcher.outputSize, stitcher.endOfPageDetected)
    }

    func preview(maxHeight: Int) -> CGImage? { stitcher.preview(maxHeight: maxHeight) }

    func assemble() throws -> CGImage { try stitcher.assemble() }
}

final class LiveStitcher: ScrollStitchService {
    private var engine = StitchEngine()
    private(set) var acceptedFrameCount = 0
    private(set) var outputSize = PixelSize(width: 0, height: 0)
    private(set) var endOfPageDetected = false

    func reset() {
        engine = StitchEngine()
        acceptedFrameCount = 0
        outputSize = PixelSize(width: 0, height: 0)
        endOfPageDetected = false
    }

    func append(_ frame: CGImage, elapsed: Duration) async -> ScrollAppendResult {
        let current = engine
        let (result, count, size, ended) = await current.append(frame, elapsed: elapsed)
        // A reset during the await replaced the engine; its counters no longer apply.
        guard current === engine else { return result }
        acceptedFrameCount = count
        outputSize = size
        endOfPageDetected = ended
        return result
    }

    func preview(maxHeight: Int) async -> CGImage? {
        await engine.preview(maxHeight: maxHeight)
    }

    func assemble() async throws -> CGImage {
        try await engine.assemble()
    }
}

extension AppServices {
    /// The production composition root: one image store shared by import, render, and export.
    static func live(settings: SettingsStore) -> AppServices {
        let store = ImageStore()
        let capture = LiveCaptureService()
        let github = LiveGitHubUpload()
        let scrollFrames = LiveScrollFrames()
        let recognition = LiveRecognition()
        return AppServices(
            githubUpload: github, githubCredentials: github,
            capture: capture, screenPermission: LiveScreenPermission(), accessibility: LiveAccessibilityPermission(),
            assets: LiveImageAssets(store: store), input: LiveImageInput(), renderer: LiveRenderer(store: store),
            exporter: LiveExporter(store: store), clipboard: LiveClipboard(), files: LiveFiles(), drag: LiveDragSink(),
            folders: LiveSaveFolders.storing(in: settings), textRecognition: recognition,
            qrDecoder: recognition, sensitiveText: LiveSensitiveText(store: store),
            scrollFrames: scrollFrames, stitcher: LiveStitcher(), autoScroller: LiveAutoScroll(frames: scrollFrames),
            loginItem: LiveLoginItem(), clock: SystemClock(), captureSound: LiveCaptureSound(),
            interfaceElements: LiveInterfaceElements(),
            diagnosticsLog: DiagnosticsLog.standardDirectory().map { DiagnosticsLog(directory: $0) })
    }
}
