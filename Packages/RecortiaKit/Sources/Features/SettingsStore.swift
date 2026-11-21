import Domain
import Foundation
import Observation

/// Preferences persisted as one versioned JSON blob (SPEC §7). Stores settings only: never
/// screenshots, OCR text, window titles, or any other content.
@MainActor
@Observable
public final class SettingsStore {
    public enum LoadIssue: Hashable, Sendable {
        /// Stored bytes could not be decoded; defaults are used and the bytes are left untouched.
        case corrupted
        /// Written by a newer Recortia; defaults are used rather than misreading it.
        case unsupportedSchema(Int)
        /// The blob grants side-effect consent but Recortia did not seal it; that consent was
        /// dropped and every other setting loaded.
        case unverifiedConsent
    }

    static let storageKey = "RecortiaPreferences"
    static let sealKey = "RecortiaPreferencesSeal"
    public static let opacityRange: ClosedRange<Double> = 0.2...1

    public private(set) var preferences: Preferences
    public private(set) var loadIssue: LoadIssue?
    /// Session-only identity: restoring the same settings cannot revive a revoked upload.
    public private(set) var githubUploadConsentID = UUID()
    /// Session-only count of the person's save-folder choices (choose, clear, or the folder asked
    /// for when turning automatic save on). A renewed bookmark for the same folder does not count,
    /// so an automatic save can tell a new choice from a moved or unreachable planned folder.
    @ObservationIgnored var saveFolderSelection = 0

    @ObservationIgnored private let storage: any PreferenceStorage
    @ObservationIgnored private let integrity: any PreferenceIntegrityService

    public init(storage: any PreferenceStorage, integrity: any PreferenceIntegrityService) {
        self.storage = storage
        self.integrity = integrity
        let (loaded, issue) = Self.load(from: storage, integrity: integrity)
        preferences = loaded
        loadIssue = issue
    }

    public func update(_ change: (inout Preferences) -> Void) {
        var updated = preferences
        change(&updated)
        updated = Self.sanitized(updated)
        guard updated != preferences else { return }
        if updated.githubUpload != preferences.githubUpload { githubUploadConsentID = UUID() }
        preferences = updated
        persist()
    }

    /// Returns the primary recognition language to Automatic when this Mac's recognizer no longer
    /// reports it (FR-08). An empty list, a recognizer that reports nothing, changes nothing.
    public func forgetUnsupportedPrimaryRecognitionLanguage(supported: [Locale.Language]) {
        guard let primary = preferences.primaryRecognitionLanguage, !supported.isEmpty,
            !supported.contains(where: { $0.maximalIdentifier == primary })
        else { return }
        update { $0.primaryRecognitionLanguage = nil }
    }

    /// Shows or hides the menu-bar icon. Returns true only when this hides it for the first time,
    /// so the caller tells the person how to get back (open Recortia again).
    @discardableResult
    public func setShowsMenuBarIcon(_ shows: Bool) -> Bool {
        let explains = !shows && preferences.showsMenuBarIcon && preferences.hasExplainedHiddenMenuBarIcon != true
        update {
            $0.showsMenuBarIcon = shows
            if explains { $0.hasExplainedHiddenMenuBarIcon = true }
        }
        return explains
    }

    /// An explicit reset is the one write allowed over a newer Recortia's blob.
    public func resetToDefaults() {
        githubUploadConsentID = UUID()
        saveFolderSelection += 1
        preferences = Preferences()
        loadIssue = nil
        persist()
    }

    private func persist() {
        // A blob from a newer Recortia stays untouched, so a downgrade never erases its settings.
        if case .unsupportedSchema = loadIssue { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Sanitized preferences contain only finite numbers, so encoding cannot fail on floats;
        // should it fail anyway, the in-memory value stays authoritative for this session.
        guard let data = try? encoder.encode(preferences) else { return }
        storage.setPreferenceData(data, forKey: Self.storageKey)
        // Without the secret the blob stays unsealed: consent then lasts only this session.
        storage.setPreferenceData(integrity.seal(data), forKey: Self.sealKey)
    }

    private static func load(
        from storage: any PreferenceStorage, integrity: any PreferenceIntegrityService
    ) -> (Preferences, LoadIssue?) {
        guard let data = storage.preferenceData(forKey: storageKey) else { return (Preferences(), nil) }
        guard let schema = try? JSONDecoder().decode(StoredSchema.self, from: data) else {
            return (Preferences(), .corrupted)
        }
        guard schema.schemaVersion <= Preferences.currentSchemaVersion else {
            return (Preferences(), .unsupportedSchema(schema.schemaVersion))
        }
        guard let decoded = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return (Preferences(), .corrupted)
        }
        let sealed = storage.preferenceData(forKey: sealKey).map { integrity.verify(data, seal: $0) } ?? false
        guard !sealed, decoded.grantsSideEffects else { return (sanitized(decoded), nil) }
        return (sanitized(decoded.withoutSideEffectConsent), .unverifiedConsent)
    }

    private struct StoredSchema: Decodable {
        let schemaVersion: Int
    }

    /// Clamps capture delay, finite JPEG quality and finite pin opacity; non-finite quality or
    /// opacity and an invalid export scale become defaults; an invalid window size and a malformed
    /// primary recognition language are discarded; a window background colour is made opaque.
    public static func sanitized(_ input: Preferences) -> Preferences {
        let defaults = Preferences()
        var output = input
        output.schemaVersion = Preferences.currentSchemaVersion
        output.launchAtLogin = false
        output.captureDelaySeconds = CaptureRequest.clampedDelay(input.captureDelaySeconds)
        output.jpegQuality = input.jpegQuality.isFinite ? min(max(input.jpegQuality, 0), 1) : defaults.jpegQuality
        if input.defaultExportFormat == .automatic {
            output.defaultExportFormat = defaults.defaultExportFormat
            output.automaticExportFormatChoice = true
        }
        output.defaultExportScale =
            input.defaultExportScale.isFinite && ExportOptions.validScaleRange.contains(input.defaultExportScale)
            ? input.defaultExportScale : defaults.defaultExportScale
        output.pinDefaultOpacity =
            input.pinDefaultOpacity.isFinite
            ? min(max(input.pinDefaultOpacity, opacityRange.lowerBound), opacityRange.upperBound)
            : defaults.pinDefaultOpacity
        output.editorContentSize = input.editorContentSize.flatMap(EditorWindowSizing.rememberable)
        output.primaryRecognitionLanguage = input.primaryRecognitionLanguage.flatMap(languageIdentifier)
        if case .solid(let color) = input.windowCaptureBackground {
            output.windowCaptureBackground = .solid(color.withAlpha(255))
        }
        // Automatic saving writes only to a folder the person chose; without one it is off.
        if input.preferredSaveFolderBookmark == nil { output.autoSave = false }
        return output
    }

    /// The full form of a BCP 47 language identifier made of ASCII letters, digits, `-` and `_`,
    /// at most 64 characters; nil for anything else.
    private static func languageIdentifier(_ text: String) -> String? {
        guard (1...64).contains(text.count),
            text.unicodeScalars.allSatisfy({
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0))
            })
        else { return nil }
        return Locale.Language(identifier: text).maximalIdentifier
    }
}
