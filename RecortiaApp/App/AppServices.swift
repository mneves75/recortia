import Features
import Foundation

/// The live service implementations, built by the composition root from the Imaging and
/// MacPlatform modules. Until that wiring lands, the app runs with `services == nil` and every
/// command that needs one of these is disabled rather than faked.
struct AppServices {
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
    let scrollFrames: any ScrollFrameSourceService
    let stitcher: any ScrollStitchService
    /// Nil when automatic scrolling is not built; manual scrolling still works.
    let autoScroller: (any AutoScrollService)?
    let loginItem: any LoginItemService
    let clock: any FeatureClock
}

/// Wall-clock implementation of `FeatureClock` for the countdown and scroll timing.
final class SystemClock: FeatureClock {
    func now() -> Date { Date() }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
