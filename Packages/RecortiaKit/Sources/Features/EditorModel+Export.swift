import Domain
import Foundation

public enum EditorExportRequest: Hashable, Sendable {
    case copy
    /// A destination the user chose in a save panel; `overwriteConfirmed` when the panel confirmed
    /// replacing an existing file.
    case save(URL, overwriteConfirmed: Bool)
    case saveToPreferredFolder
    case drag
}

// Export (FR-07) and pinning (FR-09). Every external write goes through `ExportCoordinator`
// (sanitized ShareSnapshot) or `PinsModel` (sanitized render); nothing here encodes or writes.
extension EditorModel {
    @discardableResult
    public func export(_ request: EditorExportRequest) async -> ExportOutcome {
        guard !isClosed else { return .failed(.staleDocument) }
        let action: ExportAction
        switch request {
        case .copy:
            action = .copy
        case .save(let url, let confirmed):
            action = .save(to: url, overwriteConfirmed: confirmed)
        case .drag:
            action = .drag
        case .saveToPreferredFolder:
            guard let bookmark = environment.settings.preferences.preferredSaveFolderBookmark,
                let folder = environment.folders.resolveFolder(bookmark: bookmark)
            else {
                post(.noPreferredFolder)
                return .failed(.accessDenied)
            }
            action = .saveToFolder(folder)
        }
        let revision = session.revision
        let outcome = await environment.export.export(
            action, session: session,
            currentSession: { [weak self] in
                guard let self, !self.isClosed else { return nil }
                return self.session
            })
        guard !isClosed else { return outcome }
        // The exported state is now outside the app: closing no longer needs to ask.
        if outcome.didWrite, session.revision == revision { session.markSaved() }
        if outcome != .canceled { post(.exported(outcome)) }
        return outcome
    }

    public var isExporting: Bool { environment.export.isBusy }

    public func cancelExport() { environment.export.cancel() }

    /// Pins a sanitized render of the current document.
    public func pin() async {
        guard !isClosed else { return }
        do {
            try await environment.pins.pin(
                session,
                currentSession: { [weak self] in
                    guard let self, !self.isClosed else { return nil }
                    return self.session
                })
            post(.pinned)
        } catch {
            post(.pinFailed(error))
        }
    }

    /// Ends the editor: cancels in-flight work, drops late results, and releases the pixels of
    /// every asset this editor held (undo history included). Idempotent.
    public func close() {
        guard !isClosed else { return }
        cancelGesture()
        endContinuousChange()
        textEditing = nil
        isClosed = true
        environment.export.invalidatePendingDrag(documentID: session.document.id)
        baseTask?.cancel()
        outputTask?.cancel()
        baseTask = nil
        outputTask = nil
        recognitionRequest = nil
        qrRequest = nil
        baseImage = nil
        outputPreview = nil
        for id in knownAssets { environment.assets.release(id) }
        knownAssets = []
    }
}
