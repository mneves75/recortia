import CoreGraphics
import Domain
import Foundation
import Testing

@testable import Features

// Failure modes (B-1, ADR-009): a capture held after its thumbnail was dismissed or timed out; an
// action that writes without the export pipeline, or after dismissal; the thumbnail showing before
// its automatic exports ran; a timeout while the pointer rests on it; quick actions shown for a
// capture that automatic masking must review first; Capture Text leaving its flow.
@MainActor
final class QuickActionsHarness {
    let renderer = FakeRenderService()
    let exporter = FakeExportService()
    let clipboard = FakeClipboard()
    let files = FakeFileSink()
    let drag = FakeDragSink()
    let printer = FakePrinter()
    let folders = FakeSaveFolders()
    let assets = FakeAssetService()
    let clock = ManualClock()
    let settings = SettingsStore(storage: MemoryPreferenceStorage())
    let upload = QuickUpload()
    let textClipboard = FakeTextClipboard()
    let export: ExportCoordinator
    let pins: PinsModel
    let model: QuickActionsModel
    let session = TestFixtures.session()
    private(set) var opened: [DocumentSession] = []

    init() {
        export = ExportCoordinator(
            exporter: exporter, clipboard: clipboard, files: files, drag: drag, printer: printer, folders: folders,
            clock: clock, settings: settings, upload: upload)
        pins = PinsModel(renderer: renderer, settings: settings, export: export)
        model = QuickActionsModel(
            export: export, pins: pins, renderer: renderer, assets: assets, folders: folders, settings: settings,
            clock: clock, textClipboard: textClipboard)
        model.onOpenInEditor = { [weak self] in self?.opened.append($0) }
    }

    var assetIDs: [AssetID] { Array(session.document.assets.keys) }

    /// Shows the thumbnail for `session` with no automatic export.
    func shown(_ shown: DocumentSession? = nil) async {
        let outcomes = await model.present(shown ?? session, after: export.automaticExportPlan())
        #expect(outcomes.isEmpty)
        #expect(model.isShown)
    }
}

/// Returns a link named after the uploaded snapshot's document, so a test can tell whose it is.
@MainActor
final class QuickUpload: GitHubUploadService {
    private(set) var uploaded: [DocumentID] = []

    func upload(
        _ snapshot: ShareSnapshot, to destination: GitHubDestination, intent: UUID,
        isLive: @escaping @MainActor @Sendable () -> Bool,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws(GitHubUploadFailure) -> URL {
        guard isCurrent() else { throw .staleDocument }
        uploaded.append(snapshot.documentID)
        return Self.link(for: snapshot.documentID)
    }

    static func link(for document: DocumentID) -> URL {
        URL(string: "https://github.com/fixture/captures/blob/main/\(document.raw.uuidString).png")
            ?? URL(filePath: "/")
    }
}

@Suite("Quick-action thumbnail after a capture (B-1, ADR-009)")
@MainActor
struct QuickActionsModelTests {

    @Test("After a capture opens the editor by default, also for preferences saved before the setting")
    func defaultsToEditor() throws {
        #expect(Preferences().afterCapture == .openEditor)
        var stored = Preferences()
        stored.afterCapture = .showQuickActions
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        #expect(object["afterCaptureChoice"] as? String == "showQuickActions")
        object["afterCaptureChoice"] = nil
        let older = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.afterCapture == .openEditor)
        #expect(CaptureFollowUp.decide(purpose: .edit, preferences: older) == .editor(masksSensitiveText: false))
    }

    @Test("Show quick actions routes captures to the thumbnail; masking and Capture Text keep their flows")
    func followUp() {
        var preferences = Preferences()
        preferences.afterCapture = .showQuickActions
        #expect(CaptureFollowUp.decide(purpose: .edit, preferences: preferences) == .quickActions)
        #expect(CaptureFollowUp.decide(purpose: .recognizeText, preferences: preferences) == .recognizeText)
        // Masks must land before anything shows or exports the capture: the editor reviews it.
        preferences.autoRedactsSensitiveText = true
        #expect(CaptureFollowUp.decide(purpose: .edit, preferences: preferences) == .editor(masksSensitiveText: true))
        preferences.afterCapture = .openEditor
        #expect(CaptureFollowUp.decide(purpose: .edit, preferences: preferences) == .editor(masksSensitiveText: true))
    }

    @Test("Pin after capture runs the chosen automatic batch once, then replaces the source with a pin")
    func automaticPinAfterExports() async {
        let h = QuickActionsHarness()
        let folder = URL(filePath: "/tmp/recortia-automatic-pin", directoryHint: .isDirectory)
        h.folders.folder = folder
        h.settings.update {
            $0.afterCapture = .pin
            $0.autoCopy = true
            $0.preferredSaveFolderBookmark = Data([1])
            $0.autoSave = true
        }
        let pending = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = pending
        let presenting = h.model.schedulePresentation(
            h.session, after: h.export.automaticExportPlan(), pinningIfAllowedBy: FakeScreenPermission())
        h.settings.update { $0.afterCapture = .openEditor }
        await waitFor("the automatic batch renders before pinning") { pending.waiterCount == 1 }
        #expect(h.pins.pins.isEmpty)
        #expect(!h.model.isShown)
        h.exporter.pending = nil
        pending.resolve(.success(()))
        let result = await presenting.value
        #expect(!result.permissionDenied)
        #expect(h.pins.pins.count == 1)
        #expect(h.pins.pins.first?.takesFocus == false)
        #expect(h.model.capture == nil)
        #expect(h.assets.released == h.assetIDs)
        #expect(h.clipboard.writes.map(\.documentID) == [h.session.document.id])
        #expect(h.files.uniqueSaves.map(\.folder) == [folder])
        #expect(h.upload.uploaded.isEmpty)
    }

    @Test("Pin alone creates a local reference without enabling any automatic export")
    func automaticPinAlone() async {
        let h = QuickActionsHarness()
        let permission = FakeScreenPermission()
        let result = await h.model.schedulePresentation(
            h.session, after: h.export.automaticExportPlan(), pinningIfAllowedBy: permission
        ).value
        #expect(result.exports.isEmpty && h.exporter.snapshotCount == 0)
        #expect(h.pins.pins.count == 1 && h.model.capture == nil && !h.model.isShown)
        #expect(h.assets.released == h.assetIDs)
        #expect(permission.requestCount == 0 && h.upload.uploaded.isEmpty)
    }

    @Test("A full pin budget falls back to the same thumbnail without repeating its automatic copy")
    func automaticPinLimitKeepsCapture() async throws {
        let h = QuickActionsHarness()
        let existing = try #require(makeImage())
        for _ in 0..<PinLimits.maxPins {
            try h.pins.add(existing, source: nil, displayScale: 1)
        }
        h.settings.update { $0.autoCopy = true }
        let result = await h.model.schedulePresentation(
            h.session, after: h.export.automaticExportPlan(), pinningIfAllowedBy: FakeScreenPermission()
        ).value
        #expect(result.exports == [.copied])
        #expect(h.clipboard.writes.count == 1)
        #expect(h.pins.pins.count == PinLimits.maxPins)
        #expect(h.model.isShown && !h.model.isPreparingAutomaticPin)
        #expect(h.model.capture?.session.document.id == h.session.document.id)
        #expect(h.model.capture?.automaticPinFailure == .limitReached)
        #expect(h.assets.released.isEmpty)
        h.model.openInEditor()
        #expect(h.opened.map(\.document.id) == [h.session.document.id])
        #expect(h.model.capture == nil && h.assets.released.isEmpty)
    }

    @Test("The earlier queued automatic pin cannot reclaim a replaced capture")
    func queuedAutomaticPinCannotReplaceNewCapture() async {
        let h = QuickActionsHarness()
        let plan = h.export.automaticExportPlan()
        let first = h.model.schedulePresentation(h.session, after: plan, pinningIfAllowedBy: FakeScreenPermission())
        let replacement = TestFixtures.session()
        let second = h.model.schedulePresentation(replacement, after: plan)
        _ = await first.value
        _ = await second.value
        #expect(h.pins.pins.isEmpty)
        #expect(h.model.isShown && h.model.capture?.session.document.id == replacement.document.id)
        #expect(h.assets.released == h.assetIDs)
    }

    @Test("Revoking Screen Recording during the automatic export prevents delivery and pinning")
    func revokedPermissionPreventsAutomaticDelivery() async {
        let h = QuickActionsHarness()
        let permission = FakeScreenPermission()
        h.settings.update { $0.autoCopy = true }
        let pending = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = pending
        let presenting = h.model.schedulePresentation(
            h.session, after: h.export.automaticExportPlan(), pinningIfAllowedBy: permission)
        await waitFor("the automatic copy is rendering") { pending.waiterCount == 1 }
        permission.isGranted = false
        pending.resolve(.success(()))
        let result = await presenting.value
        #expect(result.permissionDenied && result.exports.isEmpty)
        #expect(h.clipboard.writes.isEmpty && h.files.uniqueSaves.isEmpty && h.upload.uploaded.isEmpty)
        #expect(h.pins.pins.isEmpty && h.model.capture == nil)
        #expect(h.assets.released == h.assetIDs)
        #expect(permission.requestCount == 0)
    }

    @Test("A pin render returning after cancellation or permission loss releases its source", arguments: [false, true])
    func lateAutomaticPinRender(permissionLost: Bool) async throws {
        let h = QuickActionsHarness()
        let permission = FakeScreenPermission()
        let pending = Pending<Result<CGImage, ExportServiceError>>()
        h.renderer.pending = pending
        let presenting = h.model.schedulePresentation(
            h.session, after: h.export.automaticExportPlan(), pinningIfAllowedBy: permission)
        await waitFor("the automatic pin is rendering") { pending.waiterCount == 1 }
        var replacement: DocumentSession?
        if permissionLost {
            permission.isGranted = false
        } else {
            h.model.cancelAutomaticPin()
            #expect(h.assets.released == h.assetIDs)
            h.renderer.pending = nil
            let next = TestFixtures.session()
            replacement = next
            _ = await h.model.schedulePresentation(next, after: h.export.automaticExportPlan()).value
        }
        pending.resolve(.success(try #require(makeImage())))
        let result = await presenting.value
        #expect(result.permissionDenied == permissionLost)
        #expect(h.pins.pins.isEmpty && h.model.capture?.session.document.id == replacement?.document.id)
        #expect(h.model.isShown == (replacement != nil))
        #expect(h.pins.canAddPin && h.assets.released == h.assetIDs)
        #expect(h.clipboard.writes.isEmpty && permission.requestCount == 0)
    }

    @Test("The capture's automatic exports run before the thumbnail shows")
    func automaticExportsFirst() async throws {
        let h = QuickActionsHarness()
        h.settings.update { $0.autoCopy = true }
        let plan = h.export.automaticExportPlan()
        let pending = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = pending
        let presenting = Task { await h.model.present(h.session, after: plan) }
        await waitFor("the automatic copy renders") { pending.waiterCount == 1 }
        #expect(h.model.capture?.session.document.id == h.session.document.id)
        #expect(!h.model.isShown)
        #expect(h.renderer.renderCount == 0)
        #expect(h.clock.pendingSleepCount == 0)
        h.exporter.pending = nil
        pending.resolve(.success(()))
        #expect(await presenting.value == [.copied])
        #expect(h.model.isShown)
        #expect(h.clipboard.writes.map(\.documentID) == [h.session.document.id])
        // The thumbnail shows the sanitizing renderer's output, never the stored pixels.
        #expect(h.renderer.renderCount == 1 && h.model.capture?.preview != nil)
        #expect(h.assets.released.isEmpty)
    }

    @Test("Dismiss releases the capture's pixels and nothing else is kept")
    func dismissReleases() async {
        let h = QuickActionsHarness()
        await h.shown()
        h.model.dismiss()
        #expect(h.model.capture == nil && !h.model.isShown)
        #expect(h.assets.released == h.assetIDs)
        h.model.dismiss()
        #expect(h.assets.released == h.assetIDs)
    }

    @Test("The thumbnail times out after 8 s, paused while the pointer rests on it")
    func timeout() async {
        let h = QuickActionsHarness()
        await h.shown()
        await waitFor("the timer starts") { h.clock.pendingSleepCount == 1 }
        #expect(h.clock.sleepRequests.last == QuickActionsModel.timeout)
        h.model.setPointerInside(true)
        await waitFor("hovering stops the timer") { h.clock.pendingSleepCount == 0 }
        h.clock.advance(bySeconds: 60)
        await drain()
        #expect(h.model.isShown && h.assets.released.isEmpty)
        h.model.setPointerInside(false)
        await waitFor("leaving restarts the timer") { h.clock.pendingSleepCount == 1 }
        h.clock.advance(bySeconds: 7)
        await drain()
        #expect(h.model.isShown)
        h.clock.advance(bySeconds: 1)
        await waitFor("the timeout discards the capture") { h.model.capture == nil }
        #expect(h.assets.released == h.assetIDs)
    }

    @Test("Copy writes the export pipeline's snapshot, then discards the capture")
    func copy() async {
        let h = QuickActionsHarness()
        await h.shown()
        #expect(await h.model.copy() == .copied)
        #expect(h.exporter.snapshotCount == 1)
        #expect(h.clipboard.writes.map(\.documentID) == [h.session.document.id])
        #expect(h.model.capture == nil && h.assets.released == h.assetIDs)
    }

    @Test("An export still rendering when the thumbnail is dismissed writes nothing")
    func dismissDuringExport() async {
        let h = QuickActionsHarness()
        await h.shown()
        let pending = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = pending
        let copying = Task { await h.model.copy() }
        await waitFor("the copy renders") { pending.waiterCount == 1 }
        #expect(h.model.isActing)
        #expect(h.clock.pendingSleepCount == 0)
        h.model.dismiss()
        pending.resolve(.success(()))
        #expect(await !copying.value.didWrite)
        #expect(h.clipboard.writes.isEmpty)
        #expect(h.assets.released == h.assetIDs)
    }

    @Test("A failed copy keeps the thumbnail and restarts its timer")
    func failedCopyKeeps() async {
        let h = QuickActionsHarness()
        await h.shown()
        h.clipboard.error = .clipboardWriteFailed
        #expect(await h.model.copy() == .failed(.clipboardFailed))
        #expect(h.model.isShown && !h.model.isActing && h.assets.released.isEmpty)
        await waitFor("the timer restarts") { h.clock.pendingSleepCount == 1 }
    }

    @Test("Save writes into the chosen folder, otherwise to the destination the person picks")
    func save() async {
        let folder = URL(filePath: "/tmp/recortia-quick-actions", directoryHint: .isDirectory)
        let h = QuickActionsHarness()
        h.settings.update { $0.preferredSaveFolderBookmark = Data([1]) }
        h.folders.folder = folder
        await h.shown()
        var asked = 0
        let outcome = await h.model.save(
            choosing: {
                asked += 1
                return nil
            }, confirmReplacement: { _ in false })
        #expect(outcome.didWrite)
        #expect(asked == 0 && h.files.uniqueSaves.map(\.folder) == [folder])
        #expect(h.assets.released == h.assetIDs)

        let other = QuickActionsHarness()
        await other.shown()
        #expect(await other.model.save(choosing: { nil }, confirmReplacement: { _ in false }) == .canceled)
        #expect(other.model.isShown && other.files.saves.isEmpty)
        let url = URL(filePath: "/tmp/capture.png")
        other.files.existing = [url]
        var named: [URL] = []
        let replaced = await other.model.save(
            choosing: { (url, .fixed(.png)) },
            confirmReplacement: {
                named.append($0)
                return true
            })
        #expect(replaced == .saved(url) && named == [url], "the question names the file it replaces")
        #expect(other.files.saves.map(\.overwrite) == [true])
        #expect(other.assets.released == other.assetIDs)
    }

    @Test("Pin keeps a sanitized render and still releases the capture's pixels")
    func pin() async {
        let h = QuickActionsHarness()
        await h.shown()
        #expect(await h.model.pin() == nil)
        #expect(h.pins.pins.count == 1 && h.pins.pins.first?.exportID != nil)
        #expect(h.model.capture == nil && h.assets.released == h.assetIDs)
    }

    @Test("Open in Editor hands the capture over without releasing it")
    func openInEditor() async {
        let h = QuickActionsHarness()
        await h.shown()
        h.model.openInEditor()
        #expect(h.opened.map(\.document.id) == [h.session.document.id])
        #expect(h.model.capture == nil && h.assets.released.isEmpty)
        h.clock.advance(bySeconds: 60)
        await drain()
        #expect(h.assets.released.isEmpty)
    }

    @Test("Dragging out ends the thumbnail only once the receiver has the file")
    func drag() async {
        let h = QuickActionsHarness()
        await h.shown()
        h.drag.outcome = .success(.canceledByUser)
        #expect(await h.model.drag() == .canceled)
        #expect(h.model.isShown && h.assets.released.isEmpty)
        h.drag.outcome = .success(.delivered)
        #expect(await h.model.drag() == .dragged)
        #expect(h.drag.writtenSnapshots.map(\.documentID) == [h.session.document.id])
        #expect(h.model.capture == nil && h.assets.released == h.assetIDs)
    }

    @Test("A new capture replaces the thumbnail and releases the one it replaced")
    func replaced() async {
        let h = QuickActionsHarness()
        await h.shown()
        let next = TestFixtures.session()
        await h.shown(next)
        #expect(h.model.capture?.session.document.id == next.document.id)
        #expect(h.assets.released == h.assetIDs)
    }

    @Test("Copy Link copies this capture's own upload link and keeps the thumbnail")
    func copyLink() async {
        let h = QuickActionsHarness()
        h.settings.update {
            $0.githubUpload = GitHubUploadPreferences(
                destination: GitHubDestination(owner: "fixture", repository: "captures"), automatic: true)
        }
        let link = QuickUpload.link(for: h.session.document.id)
        #expect(await h.model.present(h.session, after: h.export.automaticExportPlan()) == [.uploaded(link)])
        #expect(h.model.capture?.uploadedURL == link)
        #expect(h.model.copyLink())
        #expect(h.textClipboard.writes == [link.absoluteString])
        // Copying the link is not an export of the capture: the thumbnail and its pixels stay.
        #expect(h.model.isShown && h.assets.released.isEmpty)
        await waitFor("the timer still runs") { h.clock.pendingSleepCount == 1 }

        h.textClipboard.fails = true
        #expect(!h.model.copyLink())
        #expect(h.model.isShown)
    }

    @Test("Without its own upload a capture offers no link, not even the previous capture's")
    func noLinkWithoutUpload() async {
        let h = QuickActionsHarness()
        h.settings.update {
            $0.githubUpload = GitHubUploadPreferences(
                destination: GitHubDestination(owner: "fixture", repository: "captures"), automatic: true)
        }
        _ = await h.model.present(h.session, after: h.export.automaticExportPlan())
        #expect(h.model.capture?.uploadedURL != nil)
        h.settings.update { $0.githubUpload?.automatic = false }
        let next = TestFixtures.session()
        await h.shown(next)
        #expect(h.model.capture?.session.document.id == next.document.id)
        #expect(h.model.capture?.uploadedURL == nil)
        #expect(!h.model.copyLink())
        #expect(h.textClipboard.writes.isEmpty)
        h.model.dismiss()
        #expect(!h.model.copyLink())
    }
}
