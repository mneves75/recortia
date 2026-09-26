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
        /// Written by a newer Framepin; defaults are used rather than misreading it.
        case unsupportedSchema(Int)
    }

    public static let storageKey = "FramepinPreferences"
    public static let opacityRange: ClosedRange<Double> = 0.2...1

    public private(set) var preferences: Preferences
    public private(set) var loadIssue: LoadIssue?

    @ObservationIgnored private let storage: any PreferenceStorage

    public init(storage: any PreferenceStorage) {
        self.storage = storage
        let (loaded, issue) = Self.load(from: storage)
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

    public func resetToDefaults() {
        preferences = Preferences()
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Sanitized preferences contain only finite numbers, so encoding cannot fail on floats;
        // should it fail anyway, the in-memory value stays authoritative for this session.
        guard let data = try? encoder.encode(preferences) else { return }
        storage.setPreferenceData(data, forKey: Self.storageKey)
    }

    private static func load(from storage: any PreferenceStorage) -> (Preferences, LoadIssue?) {
        guard let data = storage.preferenceData(forKey: storageKey) else { return (Preferences(), nil) }
        guard let decoded = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return (Preferences(), .corrupted)
        }
        guard decoded.schemaVersion <= Preferences.currentSchemaVersion else {
            return (Preferences(), .unsupportedSchema(decoded.schemaVersion))
        }
        return (sanitized(decoded), nil)
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
