import Foundation

// MARK: - Limits

public enum ImportLimitViolation: Error, Hashable, Sendable {
    case tooManyBytes
    case tooManyPixels
    case invalidDimensions
}

/// Hard input limits (FR-03). They protect correctness independently of performance targets.
public enum ImportLimits {
    public static let maxCompressedBytes = 64 * 1024 * 1024
    public static let maxPixelArea = 40_000_000
    /// Decoded pixels one Open With, Dock-icon drop or `open -a` request may hold over all its
    /// files: two images at the per-image limit, about 305 MiB as 8-bit RGBA. Without it ten
    /// 40 MP files keep about 1.49 GiB of source rasters (T1 security 4B).
    public static let maxOpenedPixelArea = 2 * maxPixelArea

    public static func check(byteCount: Int) -> ImportLimitViolation? {
        byteCount > maxCompressedBytes ? .tooManyBytes : nil
    }

    public static func check(pixelSize: PixelSize) -> ImportLimitViolation? {
        guard !pixelSize.isEmpty, let area = pixelSize.checkedArea else { return .invalidDimensions }
        return area > maxPixelArea ? .tooManyPixels : nil
    }
}

public enum ScrollLimit: Hashable, Sendable, Codable {
    case duration
    case frames
    case area
    case side
    case height
    /// The peak working memory of one append (`ScrollLimits.maxWorkingBytes`).
    case memory
}

/// Why an accepted scrolling capture is partial (SCR-02/04). A partial result is never labeled complete.
public enum ScrollPartialReason: Hashable, Sendable, Codable {
    case limit(ScrollLimit)
    case ambiguous(ScrollPauseReason)
    /// Automatic scrolling stopped because the page stopped moving, and the target did not
    /// confirm it was at its end: content that loads later (lazy loading) may be missing.
    case stoppedMoving
}

/// Scrolling-capture budgets (FR-10). The first limit reached ends collection.
public struct ScrollLimits: Hashable, Sendable {
    public var maxDuration: Duration
    public var maxAcceptedFrames: Int
    public var maxOutputArea: Int
    public var maxSide: Int
    public var defaultMaxHeight: Int
    /// Peak bytes a single `append` may hold at once: the accepted output rows and previous-frame
    /// planes, the incoming frame's storage, matcher scratch and bookkeeping, and reserved output
    /// growth. Checked before the incoming frame is converted. The default is SPEC §10's 512 MiB
    /// target for the heavy workflow.
    public var maxWorkingBytes: Int

    public init(
        maxDuration: Duration = .seconds(120), maxAcceptedFrames: Int = 200, maxOutputArea: Int = 40_000_000,
        maxSide: Int = 32_768, defaultMaxHeight: Int = 20_000, maxWorkingBytes: Int = 512 * 1024 * 1024
    ) {
        self.maxDuration = maxDuration
        self.maxAcceptedFrames = maxAcceptedFrames
        self.maxOutputArea = maxOutputArea
        self.maxSide = maxSide
        self.defaultMaxHeight = defaultMaxHeight
        self.maxWorkingBytes = maxWorkingBytes
    }

    public static let `default` = ScrollLimits()

    public func firstExceeded(elapsed: Duration, frames: Int, outputSize: PixelSize) -> ScrollLimit? {
        if elapsed > maxDuration { return .duration }
        if frames > maxAcceptedFrames { return .frames }
        guard let area = outputSize.checkedArea else { return .area }
        if area > maxOutputArea { return .area }
        if outputSize.width > maxSide || outputSize.height > maxSide { return .side }
        if outputSize.height > defaultMaxHeight { return .height }
        return nil
    }
}

public enum PinLimits {
    public static let maxPins = 5
    /// Total rendered pixels all pins may hold (≈192 MiB as 8-bit RGBA), part of the common memory
    /// budget (FR-09): five 40 MP pins would otherwise retain about 800 MB.
    public static let maxTotalPixels = 48_000_000
}

// MARK: - Capture request

public enum CaptureMode: Hashable, Sendable, Codable, CaseIterable {
    case region
    case display
    case window
    case repeatRegion
}

/// The capture delay's limits, shared by Settings and the capture coordinator.
public enum CaptureRequest {
    public static let maxDelaySeconds = 10

    public static func clampedDelay(_ seconds: Int) -> Int { min(max(seconds, 0), maxDelaySeconds) }
}

// MARK: - Export

public enum ExportFormat: Hashable, Sendable, Codable {
    case png
    case jpeg(quality: Double)

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }

    public var utTypeIdentifier: String {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        }
    }
}

/// The format one export asks for (FR-07): a fixed format, or Automatic, which encodes both and
/// keeps the PNG unless a JPEG is much smaller (`ExportOptions.automaticFormat`).
public enum ExportFormatChoice: Hashable, Sendable {
    case fixed(ExportFormat)
    case automatic
}

public enum ExportOptionsError: Error, Equatable, Sendable {
    case invalidScale
    case invalidQuality
    case translucentJPEGBackground
}

public struct ExportOptions: Hashable, Sendable, Codable {
    public var format: ExportFormat
    public var scale: Double
    /// JPEG has no alpha: transparency is flattened against this opaque color (FR-07).
    public var jpegBackground: RGBA
    public var filenameTemplate: FilenameTemplate
    /// Automatic: the encoder picks PNG or a JPEG, and `format` names only the PNG it starts from.
    /// The snapshot records the format its bytes are in.
    public var automaticFormat: Bool

    public init(
        format: ExportFormat = .png, scale: Double = 1, jpegBackground: RGBA = .white,
        filenameTemplate: FilenameTemplate = .default, automaticFormat: Bool = false
    ) {
        self.format = automaticFormat ? .png : format
        self.scale = scale
        self.jpegBackground = jpegBackground
        self.filenameTemplate = filenameTemplate
        self.automaticFormat = automaticFormat
    }

    public var formatChoice: ExportFormatChoice {
        get { automaticFormat ? .automatic : .fixed(format) }
        set {
            switch newValue {
            case .fixed(let fixed):
                format = fixed
                automaticFormat = false
            case .automatic:
                format = .png
                automaticFormat = true
            }
        }
    }

    public static let validScaleRange: ClosedRange<Double> = 0.1...8

    @discardableResult
    public func validated() throws -> ExportOptions {
        guard scale.isFinite, Self.validScaleRange.contains(scale) else { throw ExportOptionsError.invalidScale }
        if case .jpeg(let quality) = format {
            guard quality.isFinite, (0...1).contains(quality) else { throw ExportOptionsError.invalidQuality }
            guard jpegBackground.isOpaque else { throw ExportOptionsError.translucentJPEGBackground }
        }
        if automaticFormat, !jpegBackground.isOpaque { throw ExportOptionsError.translucentJPEGBackground }
        return self
    }
}

/// Screenshot filenames come from a `FilenameTemplate`: never window titles, recognized text,
/// account IDs, or URLs (FR-07).
public enum ExportFilename {
    /// `attempt` 1 returns `name`; later attempts insert " (n)" before the extension.
    public static func deduplicated(_ name: String, attempt: Int) -> String {
        guard attempt > 1 else { return name }
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        return ext.isEmpty ? "\(base) (\(attempt))" : "\(base) (\(attempt)).\(ext)"
    }
}

// MARK: - Preferences

public enum OCRTextMode: String, Hashable, Sendable, Codable, CaseIterable {
    case raw
    case normalizedWhitespace
    case preserveLineBreaks
}

public enum ExportFormatKind: String, Hashable, Sendable, Codable, CaseIterable {
    case png
    case jpeg
    /// PNG or JPEG by size, for saved files (FR-07). Stored apart from `defaultExportFormat`.
    case automatic
}

/// What a completed capture opens (FR-01, ADR-009).
public enum AfterCapture: String, Hashable, Sendable, Codable, CaseIterable {
    case openEditor
    /// A small thumbnail with Copy, Save, Open in Editor, Pin and Dismiss.
    case showQuickActions
}

/// What a window capture is shown over (FR-02). The captured pixels keep their transparent
/// corners and shadow; a solid colour is composited under them when the document is rendered.
public enum WindowCaptureBackground: Hashable, Sendable, Codable {
    case transparent
    /// Always opaque once sanitized, so an export of the window has no transparent pixel.
    case solid(RGBA)
}

/// User preferences. No screenshots, OCR text, or other content is ever stored here (SPEC.md §7).
/// Every side-effect toggle defaults to off.
public struct Preferences: Hashable, Sendable, Codable {
    public static let currentSchemaVersion = 2

    public var schemaVersion = Preferences.currentSchemaVersion
    public var hasCompletedOnboarding = false
    public var captureDelaySeconds = 0
    public var captureShowsCursor = false
    public var captureIncludesWindowShadow = true
    /// Stored only once the person picks one; read `windowCaptureBackground`.
    public var windowCaptureBackgroundChoice: WindowCaptureBackground?
    public var autoCopy = false
    public var autoSave = false
    /// Never read: the login item is the truth. Optional so a blob without the key still decodes;
    /// `SettingsStore.sanitized` sets it back to false, so it is always encoded, because 0.14.0
    /// and earlier require the key and rolling back must keep the person's preferences (PREF-01).
    package var launchAtLogin: Bool? = false
    public var updateChecksEnabled = false
    public var automaticScrollingEnabled = false
    /// The fixed format, PNG or JPEG; read `exportFormat`. 0.14 and earlier decode only those two,
    /// so `SettingsStore.sanitized` moves `.automatic` to `automaticExportFormatChoice`.
    public var defaultExportFormat = ExportFormatKind.png
    public var jpegQuality = 0.9
    public var defaultExportScale = 1.0
    public var ocrTextMode = OCRTextMode.preserveLineBreaks
    public var pinDefaultOpacity = 1.0
    public var preferredSaveFolderBookmark: Data?
    public var githubUpload: GitHubUploadPreferences?
    public var annotationPalette: SavedAnnotationPalette?
    /// The editor window content size the user last chose; nil until they resize an editor.
    public var editorContentSize: Size<DesktopSpace>?
    /// Stored only once the person changes them; read `zoomsWithScrollWheel` and
    /// `reversesScrollWheelZoom`.
    public var zoomsWithScrollWheelChoice: Bool?
    public var reversesScrollWheelZoomChoice: Bool?
    /// Stored only once the person changes it; read `keepsRunningInMenuBar`. Blobs written before
    /// 0.13 have no such key, and synthesized Codable cannot default a missing non-optional one.
    public var keepsRunningInMenuBarChoice: Bool?
    /// Stored only once the person changes it; read `showsMenuBarIcon`.
    public var showsMenuBarIconChoice: Bool?
    /// True once Recortia has said how to get back with the icon hidden; never said again.
    public var hasExplainedHiddenMenuBarIcon: Bool?
    /// Stored only once the person changes it; read `autoRedactsSensitiveText`. Optional for the
    /// same reason as `keepsRunningInMenuBarChoice`: blobs written before 0.15 have no such key.
    public var autoRedactsSensitiveTextChoice: Bool?
    /// Stored only once the person sets one; read `filenameTemplate` (A-9).
    public var filenameTemplateChoice: FilenameTemplate?
    /// Stored only once the person changes it; read `playsCaptureSound` (A-12).
    public var playsCaptureSoundChoice: Bool?
    /// Stored only once the person changes it; read `afterCapture` (B-1).
    public var afterCaptureChoice: AfterCapture?
    /// Stored only once the person picks a format; read `exportFormat`.
    public var automaticExportFormatChoice: Bool?
    /// The language text recognition tries first, as a full identifier (`pt-Latn-BR`); nil is
    /// Automatic (FR-08).
    public var primaryRecognitionLanguage: String?
    /// Stored only once the person picks one in the region overlay; read `regionAspect` (A-4).
    public var regionAspectChoice: SelectionAspect?
    /// Stored only once the person changes it; read `snapsToInterfaceElements` (B-7).
    public var snapsToInterfaceElementsChoice: Bool?
    /// Stored only once the person picks one in the colour picker; read `colorFormat` (A-7).
    public var colorFormatChoice: ColorFormat?

    public init() {}

    /// How the colour picker copies a colour (FR-11). HEX by default.
    public var colorFormat: ColorFormat {
        get { colorFormatChoice ?? .hex }
        set { colorFormatChoice = newValue }
    }

    /// Whether a completed capture plays a short sound (FR-01). Off by default.
    public var playsCaptureSound: Bool {
        get { playsCaptureSoundChoice ?? false }
        set { playsCaptureSoundChoice = newValue }
    }

    /// The ratio a region selection keeps (FR-02, A-4). Free by default.
    public var regionAspect: SelectionAspect {
        get { regionAspectChoice ?? .free }
        set { regionAspectChoice = newValue }
    }

    /// Whether a region selection also snaps to the interface elements of the app under the
    /// pointer, read through Accessibility (FR-02, ADR-010). Off by default.
    public var snapsToInterfaceElements: Bool {
        get { snapsToInterfaceElementsChoice ?? false }
        set { snapsToInterfaceElementsChoice = newValue }
    }

    /// What a completed capture opens; the editor by default (ADR-009).
    public var afterCapture: AfterCapture {
        get { afterCaptureChoice ?? .openEditor }
        set { afterCaptureChoice = newValue }
    }

    /// How saved and dragged files are named (FR-07). GitHub uploads keep their per-intent path
    /// (ADR-006).
    public var filenameTemplate: FilenameTemplate {
        get { filenameTemplateChoice ?? .default }
        set { filenameTemplateChoice = newValue }
    }

    /// What a new window capture is shown over (FR-02). Transparent by default.
    public var windowCaptureBackground: WindowCaptureBackground {
        get { windowCaptureBackgroundChoice ?? .transparent }
        set { windowCaptureBackgroundChoice = newValue }
    }

    /// Whether a mouse wheel zooms the editor canvas around the pointer, with Option to scroll
    /// (FR-04). Off by default: the wheel scrolls and Command-wheel zooms. Trackpad scrolling
    /// always scrolls.
    public var zoomsWithScrollWheel: Bool {
        get { zoomsWithScrollWheelChoice ?? false }
        set { zoomsWithScrollWheelChoice = newValue }
    }

    /// Whether wheel zoom runs the other way. Has an effect only while `zoomsWithScrollWheel` is on.
    public var reversesScrollWheelZoom: Bool {
        get { reversesScrollWheelZoomChoice ?? false }
        set { reversesScrollWheelZoomChoice = newValue }
    }

    /// Whether Recortia stays in the menu bar after its last window closes (FR-01). On by default;
    /// off, closing the last window quits.
    public var keepsRunningInMenuBar: Bool {
        get { keepsRunningInMenuBarChoice ?? true }
        set { keepsRunningInMenuBarChoice = newValue }
    }

    /// Whether Recortia shows its icon in the menu bar (FR-01, ADR-007). On by default. Hidden,
    /// opening Recortia again shows Settings and the global shortcuts keep working; it does not
    /// change when Recortia quits.
    public var showsMenuBarIcon: Bool {
        get { showsMenuBarIconChoice ?? true }
        set { showsMenuBarIconChoice = newValue }
    }

    /// Whether a new capture opens with secure masks over the e-mail addresses and phone numbers
    /// that on-device recognition finds (FR-06 amendment). Off by default.
    public var autoRedactsSensitiveText: Bool {
        get { autoRedactsSensitiveTextChoice ?? false }
        set { autoRedactsSensitiveTextChoice = newValue }
    }

    /// The format of saved, dragged and uploaded files (FR-07); Copy Image is always PNG.
    public var exportFormat: ExportFormatKind {
        get { automaticExportFormatChoice == true ? .automatic : defaultExportFormat }
        set {
            automaticExportFormatChoice = newValue == .automatic
            if newValue != .automatic { defaultExportFormat = newValue }
        }
    }

    public var exportOptions: ExportOptions {
        let format: ExportFormat = defaultExportFormat == .jpeg ? .jpeg(quality: jpegQuality) : .png
        return ExportOptions(
            format: format, scale: defaultExportScale, filenameTemplate: filenameTemplate,
            automaticFormat: exportFormat == .automatic)
    }
}

extension Preferences {
    /// Settings that let Recortia act on a capture without a further user action. Honored only
    /// from preferences Recortia sealed itself (SettingsStore, THREAT_MODEL.md).
    public var grantsSideEffects: Bool {
        autoCopy || autoSave || automaticScrollingEnabled || preferredSaveFolderBookmark != nil
            || githubUpload?.automatic == true
    }

    public var withoutSideEffectConsent: Preferences {
        var copy = self
        copy.autoCopy = false
        copy.autoSave = false
        copy.automaticScrollingEnabled = false
        copy.preferredSaveFolderBookmark = nil
        copy.githubUpload?.automatic = false
        return copy
    }
}
