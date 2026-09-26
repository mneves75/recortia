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
}

/// Why an accepted scrolling capture is partial (SCR-02/04). A partial result is never labeled complete.
public enum ScrollPartialReason: Hashable, Sendable, Codable {
    case limit(ScrollLimit)
    case ambiguous(ScrollPauseReason)
}

/// Scrolling-capture budgets (FR-10). The first limit reached ends collection.
public struct ScrollLimits: Hashable, Sendable {
    public var maxDuration: Duration
    public var maxAcceptedFrames: Int
    public var maxOutputArea: Int
    public var maxSide: Int
    public var defaultMaxHeight: Int

    public init(
        maxDuration: Duration = .seconds(120), maxAcceptedFrames: Int = 200, maxOutputArea: Int = 40_000_000,
        maxSide: Int = 32_768, defaultMaxHeight: Int = 20_000
    ) {
        self.maxDuration = maxDuration
        self.maxAcceptedFrames = maxAcceptedFrames
        self.maxOutputArea = maxOutputArea
        self.maxSide = maxSide
        self.defaultMaxHeight = defaultMaxHeight
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

public struct CaptureRequest: Identifiable, Hashable, Sendable {
    public let id: RequestID
    public var mode: CaptureMode
    public var delaySeconds: Int
    public var showsCursor: Bool
    public var includesWindowShadow: Bool

    public init(
        id: RequestID = RequestID(), mode: CaptureMode, delaySeconds: Int = 0, showsCursor: Bool = false,
        includesWindowShadow: Bool = true
    ) {
        self.id = id
        self.mode = mode
        self.delaySeconds = Self.clampedDelay(delaySeconds)
        self.showsCursor = showsCursor
        self.includesWindowShadow = includesWindowShadow
    }

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

    public init(format: ExportFormat = .png, scale: Double = 1, jpegBackground: RGBA = .white) {
        self.format = format
        self.scale = scale
        self.jpegBackground = jpegBackground
    }

    public static let validScaleRange: ClosedRange<Double> = 0.1...8

    @discardableResult
    public func validated() throws -> ExportOptions {
        guard scale.isFinite, Self.validScaleRange.contains(scale) else { throw ExportOptionsError.invalidScale }
        if case .jpeg(let quality) = format {
            guard quality.isFinite, (0...1).contains(quality) else { throw ExportOptionsError.invalidQuality }
            guard jpegBackground.isOpaque else { throw ExportOptionsError.translucentJPEGBackground }
        }
        return self
    }
}

/// Screenshot filenames: timestamp only. Never window titles, recognized text, account IDs, or URLs (FR-07).
public enum ExportFilename {
    public static func make(for date: Date, format: ExportFormat, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Recortia \(formatter.string(from: date)).\(format.fileExtension)"
    }

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
}

/// User preferences. No screenshots, OCR text, or other content is ever stored here (SPEC.md §7).
/// Every side-effect toggle defaults to off.
public struct Preferences: Hashable, Sendable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = Preferences.currentSchemaVersion
    public var hasCompletedOnboarding = false
    public var captureDelaySeconds = 0
    public var captureShowsCursor = false
    public var captureIncludesWindowShadow = true
    public var autoCopy = false
    public var autoSave = false
    public var launchAtLogin = false
    public var updateChecksEnabled = false
    public var automaticScrollingEnabled = false
    public var defaultExportFormat = ExportFormatKind.png
    public var jpegQuality = 0.9
    public var defaultExportScale = 1.0
    public var ocrTextMode = OCRTextMode.preserveLineBreaks
    public var pinDefaultOpacity = 1.0
    public var preferredSaveFolderBookmark: Data?

    public init() {}

    public var exportOptions: ExportOptions {
        let format: ExportFormat = defaultExportFormat == .png ? .png : .jpeg(quality: jpegQuality)
        return ExportOptions(format: format, scale: defaultExportScale)
    }
}
