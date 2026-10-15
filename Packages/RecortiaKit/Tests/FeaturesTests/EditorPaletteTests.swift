import Domain
import Features
import Foundation
import Testing

@Suite("Saved annotation colors in the editor (FR-05, FR-14)")
@MainActor
struct EditorPaletteTests {
    @Test("Explicit saving changes only the palette, preserving history and export consent")
    func savingPreservesDocumentAndPreferences() async {
        let h = EditorHarness()
        defer { h.model.close() }
        let model = h.model
        h.settings.update {
            $0.autoCopy = true
            $0.autoSave = true
            $0.automaticScrollingEnabled = true
            $0.defaultExportFormat = .jpeg
            $0.defaultExportScale = 2
            $0.githubUpload = GitHubUploadPreferences(
                destination: GitHubDestination(owner: "fixture", repository: "captures"), automatic: true)
        }
        model.selectTool(.line)
        h.drag((20, 30), (80, 90))
        model.undo()
        model.setStrokeColor(.yellow.withAlpha(10))
        let before = model.document
        let revision = model.session.revision
        let epoch = model.session.privacyEpoch
        let undoCount = model.session.undoCount
        let identity = h.settings.githubUploadConsentID
        var expected = h.settings.preferences
        var palette = SavedAnnotationPalette()
        palette.insert(.yellow)
        expected.annotationPalette = palette
        #expect(model.savedAnnotationColors.isEmpty)
        #expect(model.canSaveStrokeColor)
        #expect(model.saveCurrentStrokeColor())
        await h.settle()
        #expect(model.savedAnnotationColors == [.yellow])
        #expect(!model.canSaveStrokeColor)
        #expect(h.settings.preferences == expected)
        #expect(h.settings.githubUploadConsentID == identity)
        #expect(model.document == before)
        #expect(model.session.revision == revision)
        #expect(model.session.privacyEpoch == epoch)
        #expect(model.session.undoCount == undoCount)
        #expect(model.canRedo)
        #expect(h.exporter.snapshotCount == 0)
        #expect(h.clipboard.writes.isEmpty && h.textClipboard.writes.isEmpty)
        #expect(h.files.saves.isEmpty && h.files.uniqueSaves.isEmpty)
        #expect(h.drag.deliveries.isEmpty)
    }

    @Test("Editors share explicitly saved colors and a new settings store reloads them")
    func sharedPaletteAndReload() {
        let storage = MemoryPreferenceStorage()
        let settings = SettingsStore(storage: storage)
        let first = EditorHarness(settings: settings)
        let second = EditorHarness(settings: settings)
        defer {
            first.model.close()
            second.model.close()
        }
        first.model.setStrokeColor(.yellow)
        #expect(first.model.saveCurrentStrokeColor())
        #expect(second.model.savedAnnotationColors == [.yellow])
        second.model.setStrokeColor(.white)
        #expect(second.model.saveCurrentStrokeColor())
        #expect(first.model.savedAnnotationColors == [.yellow, .white])
        let reloadedSettings = SettingsStore(storage: storage)
        let reopened = EditorHarness(settings: reloadedSettings)
        defer { reopened.model.close() }
        #expect(reopened.model.savedAnnotationColors == [.yellow, .white])
        #expect(reloadedSettings.loadIssue == nil)
    }

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

    @Test("Applying a saved RGB color uses the existing selected-stroke command and undo/redo")
    func applyAndUndo() throws {
        let storage = MemoryPreferenceStorage()
        let settings = SettingsStore(storage: storage)
        var palette = SavedAnnotationPalette()
        palette.insert(.yellow)
        settings.update { $0.annotationPalette = palette }
        let h = EditorHarness(settings: settings)
        defer { h.model.close() }
        h.model.setStrokeColor(.red)
        h.model.selectTool(.line)
        h.drag((20, 30), (80, 90))
        let document = h.model.document
        let undoCount = h.model.session.undoCount
        let preferences = settings.preferences
        let writes = storage.writeCount
        #expect(h.model.applySavedColor(.yellow.withAlpha(0)))
        let applied = h.model.document
        #expect(try #require(applied.annotations.first).style.stroke == .yellow)
        #expect(h.model.style.stroke == .yellow)
        #expect(h.model.session.undoCount == undoCount + 1)
        #expect(settings.preferences == preferences)
        #expect(storage.writeCount == writes)
        h.model.undo()
        #expect(h.model.document == document)
        h.model.redo()
        #expect(h.model.document == applied)
        #expect(!h.model.applySavedColor(.white))
        #expect(h.model.document == applied)
        #expect(h.model.style.stroke == .yellow)
        #expect(h.model.session.undoCount == undoCount + 1)
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

    @Test("Duplicate and full-palette saves and unknown removals write nothing", arguments: [1, 12])
    func unsuccessfulChangesWriteNothing(_ count: Int) {
        let storage = MemoryPreferenceStorage()
        let settings = SettingsStore(storage: storage)
        var palette = SavedAnnotationPalette()
        for red in UInt8(0)..<UInt8(count) { palette.insert(RGBA(r: red, g: 20, b: 30)) }
        settings.update { $0.annotationPalette = palette }
        let h = EditorHarness(settings: settings)
        defer { h.model.close() }
        h.model.setStrokeColor(count == 1 ? RGBA(r: 0, g: 20, b: 30, a: 10) : .white)
        let preferences = settings.preferences
        let identity = settings.githubUploadConsentID
        let bytes = storage.values
        let writes = storage.writeCount
        #expect(!h.model.canSaveStrokeColor)
        #expect(!h.model.saveCurrentStrokeColor())
        #expect(!h.model.removeSavedColor(.red))
        #expect(settings.preferences == preferences)
        #expect(settings.githubUploadConsentID == identity)
        #expect(storage.values == bytes)
        #expect(storage.writeCount == writes)
        #expect(h.model.removeSavedColor(RGBA(r: 0, g: 20, b: 30, a: 0)))
        #expect(h.model.canSaveStrokeColor, "removing a color frees the duplicate or the full-palette slot")
    }
}
