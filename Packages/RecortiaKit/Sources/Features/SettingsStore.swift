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

    public static let storageKey = "RecortiaPreferences"
    public static let sealKey = "RecortiaPreferencesSeal"
    public static let opacityRange: ClosedRange<Double> = 0.2...1

    public private(set) var preferences: Preferences
    public private(set) var loadIssue: LoadIssue?

    @ObservationIgnored private let storage: any PreferenceStorage
    @ObservationIgnored private let integrity: any PreferenceIntegrityService

    public init(storage: any PreferenceStorage, integrity: any PreferenceIntegrityService) {
        self.storage = storage
        self.integrity = integrity
        let (loaded, issue) = Self.load(from: storage, integrity: integrity)
        preferences = loaded
        loadIssue = issue
    }

    /// Applies `change`, clamps the result to valid ranges, and persists it.
    public func update(_ change: (inout Preferences) -> Void) {
        var updated = preferences
        change(&updated)
        updated = Self.sanitized(updated)
        guard updated != preferences else { return }
        preferences = updated
        persist()
    }

    /// An explicit reset is the one write allowed over a newer Recortia's blob.
    public func resetToDefaults() {
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
        guard let decoded = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return (Preferences(), .corrupted)
        }
        guard decoded.schemaVersion <= Preferences.currentSchemaVersion else {
            return (Preferences(), .unsupportedSchema(decoded.schemaVersion))
        }
        let sealed = storage.preferenceData(forKey: sealKey).map { integrity.verify(data, seal: $0) } ?? false
        guard !sealed, decoded.grantsSideEffects else { return (sanitized(decoded), nil) }
        return (sanitized(decoded.withoutSideEffectConsent), .unverifiedConsent)
    }

    /// Clamps every numeric preference into its documented range; invalid values become defaults.
    public static func sanitized(_ input: Preferences) -> Preferences {
        let defaults = Preferences()
        var output = input
        output.schemaVersion = Preferences.currentSchemaVersion
        output.captureDelaySeconds = CaptureRequest.clampedDelay(input.captureDelaySeconds)
        output.jpegQuality = input.jpegQuality.isFinite ? min(max(input.jpegQuality, 0), 1) : defaults.jpegQuality
        output.defaultExportScale =
            input.defaultExportScale.isFinite && ExportOptions.validScaleRange.contains(input.defaultExportScale)
            ? input.defaultExportScale : defaults.defaultExportScale
        output.pinDefaultOpacity =
            input.pinDefaultOpacity.isFinite
            ? min(max(input.pinDefaultOpacity, opacityRange.lowerBound), opacityRange.upperBound)
            : defaults.pinDefaultOpacity
        return output
    }
}
