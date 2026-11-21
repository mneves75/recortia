import Domain
import Foundation
import Testing

@testable import Features

// Failure modes (FR-13, A-8): Save as Default Framing stores only part of the framing, or edits
// the document; a saved framing reaches an open document, an opened image or a pasted one; a new
// capture (screen or scrolling) ignores it; Reset leaves it applied; an aspect or balance change
// is not one undo step; a hand-edited framing outside the editor's ranges is applied.
@Suite("Default framing for new captures (FR-13)")
@MainActor
struct DefaultFramingTests {
    static let framing = Presentation(
        background: .radialGradient(center: .white, edge: RGBA(r: 1, g: 2, b: 3)), padding: 24, cornerRadius: 8,
        shadow: Presentation.Shadow(), aspect: .portrait9x16, balancesContent: false)

    @Test("Aspect and balance are framing edits, one undo step each")
    func aspectAndBalanceEdits() {
        let h = EditorHarness()
        h.model.setAspect(.square)
        h.model.setBalancesContent(false)
        #expect(h.model.document.presentation == Presentation(aspect: .square, balancesContent: false))
        #expect(h.model.session.undoCount == 2)
        h.model.undo()
        h.model.undo()
        #expect(h.model.document.presentation == .plain)
    }

    @Test("Save stores the whole framing as one preference without editing the document; Reset clears it")
    func saveAndReset() {
        let h = EditorHarness()
        h.model.setBackground(Self.framing.background)
        h.model.setPadding(24)
        h.model.setCornerRadius(8)
        h.model.setShadow(Presentation.Shadow())
        h.model.setAspect(.portrait9x16)
        h.model.setBalancesContent(false)
        let edits = h.model.session.undoCount
        let document = h.model.document
        #expect(h.model.defaultFraming == nil)

        h.model.saveDefaultFraming()
        #expect(h.settings.preferences.defaultFraming == Self.framing)
        #expect(h.model.defaultFraming == Self.framing)
        #expect(h.model.document == document && h.model.session.undoCount == edits, "not a document edit")

        h.model.resetDefaultFraming()
        #expect(h.settings.preferences.defaultFraming == nil)
        #expect(h.model.document == document, "the open document keeps its framing")
    }

    @Test("Saving or resetting never changes a document that is already open")
    func openDocumentsUnchanged() {
        let settings = SettingsStore(storage: MemoryPreferenceStorage())
        let saver = EditorHarness(settings: settings)
        let other = EditorHarness(settings: settings)
        saver.model.setAspect(.square)
        saver.model.saveDefaultFraming()
        #expect(other.model.document.presentation == .plain)
        saver.model.resetDefaultFraming()
        #expect(saver.model.document.presentation == Presentation(aspect: .square))
    }

    @Test("A new screen capture opens with the saved framing, over the window background; Reset stops it")
    func screenCapture() async {
        let h = CaptureHarness()
        h.settings.update {
            $0.windowCaptureBackground = .solid(RGBA(r: 20, g: 200, b: 90))
            $0.defaultFraming = Self.framing
        }
        h.coordinator.start(.region)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("region captured") { h.completions.count == 1 }
        #expect(h.completions[0].session.document.presentation == Self.framing)

        h.coordinator.start(.window)
        await waitFor("windows listed") { h.coordinator.selectionContext == .window([TestFixtures.window]) }
        h.coordinator.commitSelection(.window(TestFixtures.window))
        await waitFor("window captured") { h.completions.count == 2 }
        #expect(h.completions[1].session.document.presentation == Self.framing)

        h.settings.update { $0.defaultFraming = nil }
        h.coordinator.start(.region)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("plain capture") { h.completions.count == 3 }
        #expect(h.completions[2].session.document.presentation == .plain)
        #expect(h.completions[0].session.document.presentation == Self.framing, "earlier captures keep theirs")
    }

    @Test("An accepted scrolling capture opens with the saved framing")
    func scrollingCapture() async {
        let h = ScrollHarness()
        h.settings.update { $0.defaultFraming = Self.framing }
        await h.startCollecting()
        h.frames.deliver()
        await waitFor("frame 1") { h.model.acceptedFrames == 1 }
        h.model.stop()
        await waitFor("preview ready") { h.model.preview != nil }
        await h.model.accept()
        #expect(h.accepted.first?.document.presentation == Self.framing)
    }

    @Test("An opened or pasted image is not a capture and keeps no framing")
    func importsUnframed() async throws {
        let h = ImportHarness()
        h.settings.update { $0.defaultFraming = Self.framing }
        h.input.pasteboardData = Data([2])
        _ = try await h.coordinator.importImage(from: .pasteboard).get()
        #expect(h.imported.first?.document.presentation == .plain)
    }

    @Test("A stored framing outside the editor's ranges is discarded when preferences load")
    func sanitized() {
        var preferences = Preferences()
        preferences.defaultFraming = Presentation(padding: .infinity)
        #expect(SettingsStore.sanitized(preferences).defaultFraming == nil)
        preferences.defaultFraming = Presentation(cornerRadius: 10_000)
        #expect(SettingsStore.sanitized(preferences).defaultFraming == nil)
        preferences.defaultFraming = Presentation(shadow: Presentation.Shadow(radius: .nan))
        #expect(SettingsStore.sanitized(preferences).defaultFraming == nil)
        preferences.defaultFraming = Self.framing
        #expect(SettingsStore.sanitized(preferences).defaultFraming == Self.framing)
    }
}
