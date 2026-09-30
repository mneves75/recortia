# Module contracts

The public surface each RecortiaKit target exposes to the app. Workers implement these shapes;
the app composition root (`RecortiaApp/App/LiveServices.swift`, `LiveScrolling.swift`,
`LiveRecognition.swift`, `AppServices.live()`) adapts them to the service protocols in
`Packages/RecortiaKit/Sources/Features/Services.swift`. Names below are binding; parameter details may grow, but a
change to a listed signature needs the integrator's agreement.

Spaces, IDs, `Document`, `DocumentSession`, limits, and `ShareSnapshot` are in `Domain` and are
already implemented (see `Packages/RecortiaKit/Sources/Domain`). Shared value types
(`DecodedImage`, `ImportError`, `OCRResult`, `QRPayload`, `ScrollAppendResult`, `DisplayInfo`,
`WindowInfo`, `CaptureTarget`, `CaptureError`, `SinkError`) are implemented in the integrator-owned
`ContractTypes.swift` of Imaging and MacPlatform; the listings below repeat them for reference.

## Imaging (T1: decode, render, export)

```swift
public struct DecodedImage: Sendable {           // canonical: sRGB, 8-bit RGBA, orientation applied once
    public let image: CGImage
    public var pixelSize: PixelSize { get }
}
public enum ImportError: Error, Equatable, Sendable {
    case tooManyBytes, tooManyPixels, invalidDimensions, unsupportedFormat, multiFrame, corrupt
}
public enum ImageDecoder {
    public static func decode(_ data: Data) throws(ImportError) -> DecodedImage   // PNG/JPEG only, IO-01
    public static func canonicalize(_ image: CGImage) throws(ImportError) -> DecodedImage  // captures
}
public actor ImageStore {                         // the only holder of raw pixels
    public init()
    public func insert(_ image: DecodedImage, origin: AssetOrigin) -> ImageAssetInfo
    public func remove(_ id: AssetID)
    package func image(for id: AssetID) -> CGImage?   // package: never reachable from the app target
}
public struct PrivacyRenderer: Sendable {
    public init(store: ImageStore)
    /// Full sanitized, flattened output (SPEC §8 order), at `scale` × document.resizeScale.
    public func render(_ document: Document, scale: Double) async throws -> CGImage
    /// Sanitized raster layers + masks + cosmetic effects only (no annotations/presentation/callouts),
    /// covering the whole canvas; used under the editor's live annotation layer.
    public func renderBase(_ document: Document, scale: Double) async throws -> CGImage
}
public enum AnnotationRenderer {                  // shared by editor canvas and export
    public static func draw(_ annotations: [Annotation], in context: CGContext)   // context already in document space
}
public struct ExportPipeline: Sendable {
    public init(renderer: PrivacyRenderer)
    public func snapshot(of session: DocumentSession, options: ExportOptions, date: Date) async throws -> ShareSnapshot
}
public enum PixelSampler {
    public static func color(atX x: Int, y: Int, in image: CGImage) -> RGBA?   // nearest pixel, sRGB
}
```

## Imaging (T2: OCR, QR, scroll stitching)

```swift
public struct TextRecognizer: Sendable {
    public init()
    public func supportedLanguages() async -> [Locale.Language]
    public func recognize(_ image: CGImage, languages: [Locale.Language]) async throws -> OCRResult
}
public struct OCRResult: Sendable, Equatable {
    public struct Line: Sendable, Equatable { public let text: String; public let confidence: Float
                                              public let box: Rect<SourcePixelSpace> }   // top-left origin
    public let lines: [Line]
    public func text(mode: OCRTextMode) -> String
}
public struct QRPayload: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case text, webURL(URL), otherScheme(String), wifi, payment, binary }
    public let bytes: Data; public let string: String?; public let kind: Kind
}
public struct QRDecoder: Sendable {
    public init()
    public func decode(_ image: CGImage) async throws -> [QRPayload]
}
public struct ScrollStitcher: Sendable {
    public init(limits: ScrollLimits = .default)
    public mutating func append(_ frame: CGImage, elapsed: Duration) -> ScrollAppendResult
    public var acceptedFrameCount: Int { get }
    public var outputSize: PixelSize { get }
    public func preview(maxHeight: Int) -> CGImage?
    public func assemble() throws -> CGImage
}
```

## MacPlatform (T3)

```swift
public struct DisplayInfo: Sendable, Hashable {
    public let id: CGDirectDisplayID
    public let frame: Rect<DesktopSpace>          // top-left origin desktop points
    public let pointPixelScale: Double
    public let fingerprint: String               // changes when resolution/scale/arrangement changes
}
public enum DesktopGeometry {                     // AppKit (bottom-left) <-> desktop (top-left), once
    @MainActor public static func displays() -> [DisplayInfo]
    public static func desktopRect(fromAppKit rect: CGRect, primaryDisplayHeight: Double) -> Rect<DesktopSpace>
    public static func appKitRect(fromDesktop rect: Rect<DesktopSpace>, primaryDisplayHeight: Double) -> CGRect
}
public enum ScreenPermission {
    public static var isGranted: Bool { get }             // CGPreflightScreenCaptureAccess, no prompt
    @discardableResult public static func request() -> Bool   // CGRequestScreenCaptureAccess
}
public enum AccessibilityPermission {                // automatic scrolling only
    public static var isTrusted: Bool { get }
    public static func requestWithPrompt()
}
public struct WindowInfo: Sendable, Hashable, Identifiable {
    public let id: CGWindowID; public let ownerName: String; public let title: String?   // title never enters filenames
    public let frame: Rect<DesktopSpace>; public let displayID: CGDirectDisplayID
}
public enum CaptureError: Error, Equatable, Sendable {
    case permissionDenied, targetUnavailable, displayChanged, canceled, system(code: Int)
}
public actor ScreenCaptureService {
    public init()
    public func windows() async throws(CaptureError) -> [WindowInfo]
    public func capture(_ request: CaptureTarget, showsCursor: Bool, includesShadow: Bool,
                        excludingWindowNumbers: [Int]) async throws(CaptureError) -> (CGImage, CaptureGeometry)
}
public enum CaptureTarget: Sendable, Hashable {
    case region(Rect<DesktopSpace>, display: DisplayInfo), display(DisplayInfo), window(WindowInfo)
}
public final class ScrollFrameSource { … }         // SCStream for one region; bounded buffers; stop() ends stream
public final class AutoScroller { … }              // AX-based targeted scrolling; stops on focus/target change
public struct ClipboardSink {                      // NSPasteboard; tests use a private named pasteboard
    public init(pasteboard: NSPasteboard)
    @MainActor public func write(_ snapshot: ShareSnapshot) throws(SinkError)   // PNG only
}
public struct FileSink {
    public init(fileManager: FileManager = .default)
    public func save(_ snapshot: ShareSnapshot, to url: URL, overwrite: Bool) throws(SinkError) -> URL   // atomic
    public func saveUnique(_ snapshot: ShareSnapshot, in folder: URL) throws(SinkError) -> URL
}
public enum SinkError: Error, Equatable, Sendable {
    case clipboardWriteFailed, destinationExists, accessDenied, diskFull, volumeUnavailable, writeFailed(code: Int)
}
@MainActor public final class DragOutProvider: NSObject, NSFilePromiseProviderDelegate {
    // Writes only under the lease (Domain.ExportLease: active → committing → committed | revoked);
    // reports the real write outcome, since AppKit ends the drag session before it asks for the file.
    public init(snapshot: ShareSnapshot, lease: ExportLease = ExportLease(),
                onWriteFinished: (@Sendable (WriteOutcome) -> Void)? = nil)
}
@MainActor public final class PendingOffer<Outcome> { … }  // one user-paced offer; stale completions ignored
@MainActor public final class KeychainPreferenceIntegrity { … }  // PreferenceSeal over the data-protection keychain
public enum ImageInput {
    public static func readFile(at url: URL) throws(ImportError) -> Data      // bounded by ImportLimits
    @MainActor public static func readPasteboard(_ pasteboard: NSPasteboard) -> Data?   // explicit Paste only
}
public enum LoginItem { @MainActor public static var isEnabled: Bool; @MainActor public static func set(_ on: Bool) throws }
public enum ExternalLinkPolicy { public static func canOpen(_ url: URL) -> Bool }   // http/https only, after user action
```

## Features: editor adjustment ownership

`EditorModel` runs on MainActor. `beginContinuousChange() -> UUID` returns the current
adjustment's identity; `endContinuousChange(_ id: UUID)` closes only that adjustment. Delayed
color callbacks retain the identity they began with. A slider first ends the preceding adjustment,
then begins its own; a canvas gesture also ends the preceding adjustment before opening its group.
The parameterless `endContinuousChange()` explicitly finishes the currently open adjustment.

Preview cancellation retains ownership of an in-flight render until it completes. Re-enabling the
preview queues the latest document rather than starting a second concurrent render. Canceled or
stale results cannot publish output or failure notices for a replacement request.
