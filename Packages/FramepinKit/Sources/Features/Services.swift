import CoreGraphics
import Domain
import Foundation
import Imaging
import MacPlatform

// Service boundaries the app's composition root fulfils (SPEC.md §6). Each protocol covers one
// external or nondeterministic boundary so the feature models stay testable without the app.
// The protocols are main-actor isolated: models call them from the UI actor, and adapters that
// wrap Imaging/MacPlatform actors or `@concurrent` functions do the off-main work themselves.
// In-memory fakes live only in the FeaturesTests target.

// MARK: - Capture

@MainActor
public protocol CaptureService: AnyObject {
    /// Connected displays in desktop space. Cheap and synchronous (DesktopGeometry.displays()).
    func displays() -> [DisplayInfo]
    /// Shareable on-screen windows for the chooser, excluding Framepin's own windows.
    func windows() async throws(CaptureError) -> [WindowInfo]
    /// One-shot still capture of `target`; Framepin's overlay, editor, and pin windows are excluded.
    func capture(_ target: CaptureTarget, showsCursor: Bool, includesShadow: Bool) async throws(CaptureError)
        -> (CGImage, CaptureGeometry)
}

@MainActor
public protocol ScreenPermissionService: AnyObject {
    /// Preflight only; never prompts.
    var isGranted: Bool { get }
    /// Requests access just in time, showing the OS flow when the system allows it.
    func request() async -> Bool
}

@MainActor
public protocol AccessibilityPermissionService: AnyObject {
    /// Whether the process is trusted for Accessibility (automatic scrolling only).
    var isTrusted: Bool { get }
    /// Shows the OS prompt. Called only after the user opts into automatic scrolling.
    func requestWithPrompt()
}

// MARK: - Assets and import

@MainActor
public protocol ImageAssetService: AnyObject {
    /// Bounded decode of PNG/JPEG bytes and registration in the image store (IO-01).
    func importImage(_ data: Data, origin: AssetOrigin) async throws(ImportError) -> ImageAssetInfo
    /// Canonicalizes a captured image and registers it with its capture geometry.
    func registerCapture(_ image: CGImage, geometry: CaptureGeometry) async throws(ImportError) -> ImageAssetInfo
    /// Registers a stitched scrolling capture; `partialReason` is non-nil for an accepted partial result.
    func registerStitched(_ image: CGImage, partialReason: String?) async throws(ImportError) -> ImageAssetInfo
    /// Releases an asset's pixels when no document references it any more.
    func release(_ id: AssetID)
}

@MainActor
public protocol ImageInputService: AnyObject {
    /// Reads a local file within ImportLimits; never follows remote URLs.
    func readFile(at url: URL) async throws(ImportError) -> Data
    /// Reads image data from the general pasteboard. Called only for an explicit Paste (no polling).
    func readPasteboardImage() -> Data?
}

// MARK: - Render and export

@MainActor
public protocol RenderService: AnyObject {
    /// Full sanitized, flattened output (SPEC §8) at `scale` × document.resizeScale.
    func render(_ document: Document, scale: Double) async throws -> CGImage
    /// Sanitized raster layers, masks, and cosmetic effects only; used under the live annotation layer.
    func renderBase(_ document: Document, scale: Double) async throws -> CGImage
}

/// Failure reported by the export pipeline adapter, already mapped to the domain category.
public struct ExportServiceError: Error, Hashable, Sendable {
    public let failure: ExportFailure

    public init(_ failure: ExportFailure) {
        self.failure = failure
    }
}

@MainActor
public protocol ExportService: AnyObject {
    /// Sanitizes, renders, and encodes one immutable snapshot of `session` (ExportPipeline).
    func makeSnapshot(of session: DocumentSession, options: ExportOptions, date: Date) async throws(ExportServiceError)
        -> ShareSnapshot
}

@MainActor
public protocol ClipboardSinkService: AnyObject {
    /// Replaces the clipboard with the snapshot's sanitized PNG only after encoding succeeded.
    func write(_ snapshot: ShareSnapshot) throws(SinkError)
}

@MainActor
public protocol FileSinkService: AnyObject {
    /// Atomic save to a user-chosen URL. `overwrite` is true only after the user confirmed it.
    func save(_ snapshot: ShareSnapshot, to url: URL, overwrite: Bool) async throws(SinkError) -> URL
    /// Atomic save with a collision-free name inside a previously authorized folder.
    func saveUnique(_ snapshot: ShareSnapshot, in folder: URL) async throws(SinkError) -> URL
}

public enum DragDeliveryOutcome: Hashable, Sendable {
    /// The receiving app took the complete file.
    case delivered
    /// The user canceled the drag before any receiver accepted it.
    case canceledByUser
}

@MainActor
public protocol DragSinkService: AnyObject {
    /// Offers the snapshot as a file promise and returns once the drag session ends.
    func deliver(_ snapshot: ShareSnapshot) async throws(SinkError) -> DragDeliveryOutcome
}

@MainActor
public protocol SaveFolderService: AnyObject {
    /// Resolves the preferred save folder bookmark, or nil when absent, stale, or revoked.
    func resolveFolder(bookmark: Data) -> URL?
}

// MARK: - OCR and QR

@MainActor
public protocol TextRecognitionService: AnyObject {
    func supportedLanguages() async -> [Locale.Language]
    func recognize(_ image: CGImage, languages: [Locale.Language]) async throws -> OCRResult
}

@MainActor
public protocol QRDecodingService: AnyObject {
    func decode(_ image: CGImage) async throws -> [QRPayload]
}

// MARK: - Scrolling capture

@MainActor
public protocol ScrollFrameSourceService: AnyObject {
    /// Starts one bounded stream for `target`. Only called during an explicit scrolling session.
    func start(_ target: CaptureTarget) async throws(CaptureError)
    /// The next stable viewport frame. Throws `.canceled` after `stop()`, `.targetUnavailable` when
    /// the target disappears, `.permissionDenied` on revocation, and `.displayChanged` on reconfiguration.
    func nextFrame() async throws(CaptureError) -> CGImage
    /// Ends the stream and releases frame buffers. Idempotent.
    func stop()
}

@MainActor
public protocol ScrollStitchService: AnyObject {
    /// Discards all accepted frames and starts a new stitch.
    func reset()
    /// Offers a frame to the stitcher; matching runs off the main actor in the adapter.
    func append(_ frame: CGImage, elapsed: Duration) async -> ScrollAppendResult
    var acceptedFrameCount: Int { get }
    var outputSize: PixelSize { get }
    func preview(maxHeight: Int) async -> CGImage?
    func assemble() async throws -> CGImage
}

public enum AutoScrollStep: Hashable, Sendable {
    case scrolled
    case reachedEnd
    /// The target or focus changed; synthetic scrolling must stop immediately.
    case targetLost
}

@MainActor
public protocol AutoScrollService: AnyObject {
    /// Sends one minimal scroll action to the chosen target (Accessibility, automatic mode only).
    func step(_ target: CaptureTarget) async -> AutoScrollStep
    func stop()
}

// MARK: - System

@MainActor
public protocol LoginItemService: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
public protocol FeatureClock: AnyObject {
    func now() -> Date
    /// Suspends for `duration`; throws `CancellationError` when the calling task is canceled.
    func sleep(for duration: Duration) async throws
}

/// Key–value storage for the single preferences blob. `UserDefaults` conforms in production.
@MainActor
public protocol PreferenceStorage: AnyObject {
    func preferenceData(forKey key: String) -> Data?
    func setPreferenceData(_ data: Data?, forKey key: String)
}

extension UserDefaults: PreferenceStorage {
    public func preferenceData(forKey key: String) -> Data? { data(forKey: key) }

    public func setPreferenceData(_ data: Data?, forKey key: String) {
        if let data { set(data, forKey: key) } else { removeObject(forKey: key) }
    }
}

/// Best-effort check whether a global shortcut can be registered with the system.
@MainActor
public protocol ShortcutRegistrationProbe: AnyObject {
    /// Returns false when registration failed (for example, another app holds the combination).
    func canRegister(shortcutNamed name: String) -> Bool
}
