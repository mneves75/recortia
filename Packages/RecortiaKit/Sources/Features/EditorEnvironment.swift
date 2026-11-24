import Domain
import Foundation

// Services the editor needs beyond Services.swift. Like those, they are main-actor boundaries the
// composition root fulfils; tests use in-memory fakes.

/// Plain-text clipboard writes for recognized text, QR payloads, and sampled colors.
@MainActor
public protocol TextClipboardService: AnyObject {
    /// Replaces the clipboard with `text` as plain text only. Called only from an explicit Copy
    /// action; returns false when the write failed.
    func writePlainText(_ text: String) -> Bool
}

/// Hands a web link to the system. The editor calls it only after an explicit click and only for
/// URLs `ExternalLinkPolicy.canOpen` allows (FR-08, OCR-02).
@MainActor
public protocol ExternalLinkOpenerService: AnyObject {
    func open(_ url: URL) -> Bool
}

/// Everything one editor window needs. Built once by the composition root and shared by every
/// editor; it holds no document state.
@MainActor
public struct EditorEnvironment {
    public let renderer: any RenderService
    public let export: ExportCoordinator
    public let folders: any SaveFolderService
    public let textRecognition: any TextRecognitionService
    public let qrDecoder: any QRDecodingService
    public let sensitiveText: any SensitiveTextService
    public let assets: any ImageAssetService
    public let imageImporter: ImageImporter
    public let pins: PinsModel
    public let textClipboard: any TextClipboardService
    public let links: any ExternalLinkOpenerService
    public let settings: SettingsStore
    /// Times the automatic-masking deadline.
    public let clock: any FeatureClock
    /// Recognition and automatic-masking outcomes for the optional diagnostics file (B-10).
    public let diagnostics: (any DiagnosticsSink)?

    public init(
        renderer: any RenderService, export: ExportCoordinator, folders: any SaveFolderService,
        textRecognition: any TextRecognitionService, qrDecoder: any QRDecodingService,
        sensitiveText: any SensitiveTextService, assets: any ImageAssetService, input: any ImageInputService,
        pins: PinsModel, textClipboard: any TextClipboardService, links: any ExternalLinkOpenerService,
        settings: SettingsStore, clock: any FeatureClock, imageImporter: ImageImporter? = nil,
        diagnostics: (any DiagnosticsSink)? = nil
    ) {
        self.renderer = renderer
        self.export = export
        self.folders = folders
        self.textRecognition = textRecognition
        self.qrDecoder = qrDecoder
        self.sensitiveText = sensitiveText
        self.assets = assets
        self.imageImporter = imageImporter ?? ImageImporter(input: input, assets: assets)
        self.pins = pins
        self.textClipboard = textClipboard
        self.links = links
        self.settings = settings
        self.clock = clock
        self.diagnostics = diagnostics
    }
}
