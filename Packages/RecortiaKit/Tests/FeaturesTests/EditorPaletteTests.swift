import Domain
import Features
import Foundation
import Testing

@Suite("Saved annotation colors in the editor (FR-05, FR-14)")
@MainActor
struct EditorPaletteTests {

    @Test("Removing an explicit saved RGB color changes no annotation, history, or other preference")
    func removalPreservesDocumentAndPreferences() {
        let storage = MemoryPreferenceStorage()
        let settings = SettingsStore(storage: storage)
        var palette = SavedAnnotationPalette()
        palette.insert(.red)
        palette.insert(.yellow)
        palette.insert(.white)
        settings.update {
            $0.annotationPalette = palette
            $0.autoCopy = true
            $0.githubUpload = GitHubUploadPreferences(
                destination: GitHubDestination(owner: "fixture", repository: "captures"), automatic: true)
        }
        let h = EditorHarness(settings: settings)
        let other = EditorHarness(settings: settings)
        defer {
            h.model.close()
            other.model.close()
        }
        h.model.setStrokeColor(.yellow)
        h.model.selectTool(.line)
        h.drag((20, 30), (80, 90))
        let document = h.model.document
        let revision = h.model.session.revision
        let undoCount = h.model.session.undoCount
        let identity = settings.githubUploadConsentID
        var expected = settings.preferences
        palette.remove(.yellow)
        expected.annotationPalette = palette
        #expect(h.model.removeSavedColor(.yellow.withAlpha(0)))
        #expect(settings.preferences == expected)
        #expect(settings.githubUploadConsentID == identity)
        #expect(other.model.savedAnnotationColors == [.red, .white])
        #expect(SettingsStore(storage: storage).preferences == expected)
        #expect(h.model.document == document)
        #expect(h.model.session.revision == revision)
        #expect(h.model.session.undoCount == undoCount)
        #expect(h.model.style.stroke == .yellow)
        #expect(h.exporter.snapshotCount == 0)
        #expect(h.clipboard.writes.isEmpty && h.textClipboard.writes.isEmpty)
    }

    @Test("Applying a saved color is separate from a preceding color-well adjustment")
    func applyEndsPrecedingContinuousChange() {
        let storage = MemoryPreferenceStorage()
        let settings = SettingsStore(storage: storage)
        var palette = SavedAnnotationPalette()
        palette.insert(.yellow)
        settings.update { $0.annotationPalette = palette }
        let h = EditorHarness(settings: settings)
        defer { h.model.close() }
        h.model.selectTool(.rectangle)
        h.drag((20, 30), (80, 90))
        let initial = h.model.document
        let priorChange = h.model.beginContinuousChange()
        h.model.setStrokeColor(.black)
        let adjusted = h.model.document
        #expect(h.model.applySavedColor(.yellow))
        let applied = h.model.document
        #expect(!h.model.session.isGrouping)
        h.model.undo()
        #expect(h.model.document == adjusted)
        h.model.undo()
        #expect(h.model.document == initial)
        h.model.redo()
        #expect(h.model.document == adjusted)
        h.model.redo()
        #expect(h.model.document == applied)
        let nextChange = h.model.beginContinuousChange()
        #expect(nextChange != priorChange)
        h.model.endContinuousChange(priorChange)
        #expect(h.model.session.isGrouping, "a stale coalescer cannot end a newer gesture")
        h.model.endContinuousChange(nextChange)
    }

    @Test("Rejecting an unsaved color leaves the ongoing color-well gesture intact")
    func rejectedApplyPreservesContinuousChange() {
        let h = EditorHarness()
        defer { h.model.close() }
        h.model.selectTool(.rectangle)
        h.drag((20, 30), (80, 90))
        let change = h.model.beginContinuousChange()
        h.model.setStrokeColor(.black)
        let document = h.model.document
        let revision = h.model.session.revision
        #expect(!h.model.applySavedColor(.yellow))
        #expect(h.model.document == document)
        #expect(h.model.session.revision == revision)
        #expect(h.model.session.isGrouping)
        #expect(h.model.beginContinuousChange() == change)
        h.model.endContinuousChange(change)
    }

    @Test("Closed editors refuse every palette action, including applying a known color")
    func closedEditorRefusesPaletteActions() {
        let storage = MemoryPreferenceStorage()
        let settings = SettingsStore(storage: storage)
        var palette = SavedAnnotationPalette()
        palette.insert(.yellow)
        settings.update { $0.annotationPalette = palette }
        let h = EditorHarness(settings: settings)
        h.model.setStrokeColor(.red)
        let document = h.model.document
        let preferences = settings.preferences
        let identity = settings.githubUploadConsentID
        let writes = storage.writeCount
        h.model.close()
        #expect(!h.model.canSaveStrokeColor)
        #expect(!h.model.saveCurrentStrokeColor())
        #expect(!h.model.applySavedColor(.yellow))
        #expect(!h.model.removeSavedColor(.yellow))
        #expect(h.model.style.stroke == .red)
        #expect(h.model.document == document)
        #expect(h.model.session.undoCount == 0)
        #expect(settings.preferences == preferences)
        #expect(settings.githubUploadConsentID == identity)
        #expect(storage.writeCount == writes)
    }

    @Test("A future schema refuses every palette action and preserves its original bytes")
    func futureSchemaRefusesPaletteActions() throws {
        let storage = MemoryPreferenceStorage()
        var future = Preferences()
        future.schemaVersion = Preferences.currentSchemaVersion + 1
        let data = try JSONEncoder().encode(future)
        storage.values[SettingsStore.storageKey] = data
        let settings = SettingsStore(storage: storage)
        var palette = SavedAnnotationPalette()
        palette.insert(.yellow)
        // Existing SettingsStore permits session-only updates while protecting the newer blob.
        settings.update { $0.annotationPalette = palette }
        let h = EditorHarness(settings: settings)
        defer { h.model.close() }
        h.model.setStrokeColor(.red)
        let preferences = settings.preferences
        let identity = settings.githubUploadConsentID
        #expect(settings.loadIssue == .unsupportedSchema(Preferences.currentSchemaVersion + 1))
        #expect(h.model.savedAnnotationColors == [.yellow], "known membership makes the denial non-vacuous")
        #expect(!h.model.canSaveStrokeColor)
        #expect(!h.model.saveCurrentStrokeColor())
        #expect(!h.model.applySavedColor(.yellow))
        #expect(!h.model.removeSavedColor(.yellow))
        #expect(h.model.style.stroke == .red)
        #expect(settings.preferences == preferences)
        #expect(settings.githubUploadConsentID == identity)
        #expect(storage.values[SettingsStore.storageKey] == data)
        #expect(storage.writeCount == 0)
    }

}
