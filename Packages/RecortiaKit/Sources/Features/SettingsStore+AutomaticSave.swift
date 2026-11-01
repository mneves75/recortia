import Domain
import Foundation

/// The folder automatic saves go to (FR-07), as Settings shows it.
public enum AutomaticSaveFolder: Equatable, Sendable {
    case notChosen
    case available(URL)
    /// Chosen, but not reachable now (deleted, unmounted, or no longer accessible). It stays
    /// remembered, and an automatic save fails visibly instead of writing anywhere else.
    case unavailable
}

extension SettingsStore {
    public func automaticSaveFolder(resolvingWith folders: any SaveFolderService) -> AutomaticSaveFolder {
        guard let bookmark = preferences.preferredSaveFolderBookmark else { return .notChosen }
        return folders.resolveFolder(bookmark: bookmark).map(AutomaticSaveFolder.available) ?? .unavailable
    }

    /// Turns automatic saving on or off. Turning it on without a reachable folder asks for one
    /// first (`chooseFolder`); a cancel (nil) or a folder whose access cannot be remembered
    /// (thrown) leaves every setting as it was.
    public func setAutomaticSave(
        _ enabled: Bool, folders: any SaveFolderService, chooseFolder: () throws -> URL?
    ) throws {
        guard enabled else { return update { $0.autoSave = false } }
        if case .available = automaticSaveFolder(resolvingWith: folders) { return update { $0.autoSave = true } }
        guard let bookmark = try chosenBookmark(chooseFolder) else { return }
        update {
            $0.preferredSaveFolderBookmark = bookmark
            $0.autoSave = true
        }
    }

    /// Replaces the folder. A cancel or a folder whose access cannot be remembered changes nothing.
    public func chooseAutomaticSaveFolder(_ chooseFolder: () throws -> URL?) throws {
        guard let bookmark = try chosenBookmark(chooseFolder) else { return }
        update { $0.preferredSaveFolderBookmark = bookmark }
    }

    /// Forgets the folder and turns automatic saving off in the same change.
    public func clearAutomaticSaveFolder() {
        update {
            $0.preferredSaveFolderBookmark = nil
            $0.autoSave = false
        }
    }

    private func chosenBookmark(_ chooseFolder: () throws -> URL?) throws -> Data? {
        try chooseFolder()?.bookmarkData()
    }
}
