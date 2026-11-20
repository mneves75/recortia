import CoreGraphics
import Domain
import Foundation
import Imaging
import RecortiaFixtures
import Testing

@testable import Features

/// A new capture over a real `ImageStore` and the real `ExportPipeline`: white, with one secret
/// patch where the fake detector reports an e-mail address. Two of them that differ only in the
/// secret's color must export identical bytes once masked.
@MainActor
private struct MaskingCapture {
    static let secret = FixtureRect(x: 40, y: 30, width: 120, height: 24)
    static let region = PixelRect(x: 36, y: 26, width: 128, height: 32)
    static let folder = URL(fileURLWithPath: "/tmp/recortia-tests/automatic-masking", isDirectory: true)

    let harness: EditorHarness
    let store: ImageStore
    let model: EditorModel

    /// `green` changes the secret's pixels; everything else is the same.
    init(
        green: UInt8 = 0, upload: (any GitHubUploadService)? = nil, configure: (EditorHarness) -> Void = { _ in }
    ) async throws {
        let store = ImageStore()
        let image = try SecretExport.image(width: 400, height: 300, secrets: [Self.secret], green: green)
        let info = await store.insert(
            try ImageDecoder.canonicalize(image),
            origin: .captured(EditorFixtures.captureGeometry(width: 400, height: 300, scale: 2)))
        let session = DocumentSession(document: Document(asset: info))
        // The harness's own editor is a second, unmasked document; only `model` is the capture.
        let harness = EditorHarness(upload: upload)
        harness.assets.store = store
        harness.exporter.pipeline = ExportPipeline(renderer: PrivacyRenderer(store: store))
        harness.sensitiveText.regions = [Self.region]
        harness.sensitiveText.pending = Pending<Void>()
        configure(harness)
        self.harness = harness
        self.store = store
        model = EditorModel(session: session, environment: harness.model.environment, autoRedacts: true)
    }

    func waitForDetection() async {
        await waitFor("detection started") { harness.sensitiveText.pending?.waiterCount == 1 }
    }

    func finishDetection() async {
        harness.sensitiveText.pending?.resolve(())
        await waitFor("masking settled") { model.autoRedaction != .pending }
    }

    func exportedPixels(_ snapshot: ShareSnapshot) throws -> DecodedPixels {
        try ContainerInspector.decodePixels(snapshot.bytes)
    }

    func secretPixels(_ snapshot: ShareSnapshot, green: UInt8 = 0) throws -> Int {
        SecretExport.secretPixels(in: try exportedPixels(snapshot), Self.secret, green: green)
    }
}

/// A synthetic upload sink: records every snapshot it receives and writes only a current one.
@MainActor
private final class MaskingUpload: GitHubUploadService {
    private(set) var received: [ShareSnapshot] = []
    private(set) var written: [ShareSnapshot] = []

    func upload(
        _ snapshot: ShareSnapshot, to destination: GitHubDestination, intent: UUID,
        isLive: @escaping @MainActor @Sendable () -> Bool,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws(GitHubUploadFailure) -> URL {
        received.append(snapshot)
        guard isCurrent() else { throw .staleDocument }
        written.append(snapshot)
        return URL(fileURLWithPath: "/tmp/recortia-tests/synthetic-masked-upload.png")
    }
}

@Suite("Automatic masking of new captures (FR-06 amendment)")
@MainActor
struct EditorAutoRedactionTests {
    private func enableCopyAndSave(_ h: EditorHarness) {
        h.settings.update {
            $0.autoCopy = true
            $0.autoSave = true
            $0.preferredSaveFolderBookmark = Data([1])
        }
        h.folders.folder = MaskingCapture.folder
    }

    @Test("Automatic copy and save publish masked bytes: captures that differ only in the secret export identically")
    func automaticBatchExportsMaskedBytes() async throws {
        var copies: [ShareSnapshot] = []
        var saves: [ShareSnapshot] = []
        for green: UInt8 in [0, 200] {
            let capture = try await MaskingCapture(green: green, configure: enableCopyAndSave)
            defer { capture.model.close() }
            let plan = capture.harness.export.automaticExportPlan()
            let batch = Task { await capture.model.runAutomaticExports(plan) }
            await capture.waitForDetection()
            #expect(capture.harness.exporter.snapshotCount == 0, "the batch waits for the masks")
            await capture.finishDetection()
            let outcomes = await batch.value
            #expect(outcomes.count == 2 && outcomes.allSatisfy(\.didWrite), "\(outcomes)")
            let copy = try #require(capture.harness.clipboard.writes.first)
            let save = try #require(capture.harness.files.uniqueSaves.first?.snapshot)
            let pixels = try capture.exportedPixels(copy)
            #expect(SecretExport.secretPixels(in: pixels, MaskingCapture.secret, green: green) == 0)
            #expect(copy.revision == capture.model.session.revision, "the batch exported the masked state")
            copies.append(copy)
            saves.append(save)
        }
        #expect(copies.count == 2 && copies[0].bytes == copies[1].bytes)
        #expect(saves.count == 2 && saves[0].bytes == saves[1].bytes)
    }

    @Test("While masking is pending every edit, selection, export, pin, preview and recognition is refused")
    func pendingRefusesEverything() async throws {
        let capture = try await MaskingCapture()
        let (h, model) = (capture.harness, capture.model)
        defer { model.close() }
        await capture.waitForDetection()
        let before = model.session
        let id = before.document.id

        model.selectTool(.loupe)
        model.pointerMoved(to: Point(x: 50, y: 40))
        #expect(model.notice == nil, "hovering the loupe over a pending capture says nothing")
        model.selectTool(.redact)
        model.pointerDown(at: Point(x: 10, y: 10))
        model.pointerDragged(to: Point(x: 90, y: 60))
        model.pointerUp(at: Point(x: 90, y: 60))
        model.selectTool(.rectangle)
        model.pointerDown(at: Point(x: 200, y: 100))
        model.pointerDragged(to: Point(x: 260, y: 160))
        model.pointerUp(at: Point(x: 260, y: 160))
        model.setFillColor(.black)
        model.expandCanvas(top: 20)
        model.setCrop(Rect(x: 0, y: 0, width: 100, height: 100))
        model.selectAll()
        model.setSelection([.layer(before.document.layers[0].id)])
        model.undo()
        let imported = await model.addImageLayer(from: .droppedData(Data([0x89, 0x50])))
        #expect(!imported)
        #expect(model.session.document == before.document && model.session.revision == before.revision)
        #expect(model.selection.isEmpty)
        #expect(!model.canStartExport)

        #expect(await model.export(.copy) == .failed(.maskingUnfinished))
        #expect(await model.export(.drag) == .failed(.maskingUnfinished))
        #expect(await model.export(.saveToPreferredFolder) == .failed(.maskingUnfinished))
        #expect(
            await model.export(
                .save(MaskingCapture.folder.appending(path: "x.png"), format: .png, overwriteConfirmed: true))
                == .failed(.maskingUnfinished))
        await model.pin()
        model.setShowsOutputPreview(true)
        await model.recognizeText()
        await model.decodeQR()
        await drain()

        #expect(model.notice == .maskingInProgress)
        #expect(h.exporter.snapshotCount == 0 && h.clipboard.writes.isEmpty && h.drag.deliveries.isEmpty)
        #expect(h.files.saves.isEmpty && h.files.uniqueSaves.isEmpty)
        #expect(h.pins.pins.isEmpty && !h.renderer.fullRenders.contains { $0.id == id })
        #expect(!model.showsOutputPreview && model.outputPreview == nil)
        #expect(h.recognizer.recognizedSizes.isEmpty && h.qr.decodeCount == 0)
        // The canvas model holds no capture pixels while masking runs.
        #expect(model.baseImage == nil && model.calloutBaseImage == nil)
        #expect(!h.renderer.baseRenders.contains { $0.id == id }, "no base render of the unmasked capture")

        await capture.finishDetection()
        #expect(model.autoRedaction == .done)
        await h.settle()
        #expect(model.baseImage != nil && model.document.masks.count == 1)
        let renders = h.renderer.baseRenders.filter { $0.id == id }
        #expect(!renders.isEmpty && renders.allSatisfy { $0.masks.count == 1 }, "the first base render is masked")
    }

    @Test("A Settings change during masking neither joins nor redirects the capture's batch")
    func settingsChangeDuringMasking() async throws {
        let capture = try await MaskingCapture { h in
            h.settings.update {
                $0.autoCopy = true
                $0.autoSave = true
                $0.preferredSaveFolderBookmark = Data([1])
                $0.autoRedactsSensitiveText = true
            }
            h.folders.folder = MaskingCapture.folder
        }
        let h = capture.harness
        defer { capture.model.close() }
        let plan = h.export.automaticExportPlan()
        let batch = Task { await capture.model.runAutomaticExports(plan) }
        await capture.waitForDetection()
        let other = URL(fileURLWithPath: "/tmp/recortia-tests/other-folder", isDirectory: true)
        h.settings.update {
            $0.autoRedactsSensitiveText = false
            $0.preferredSaveFolderBookmark = Data([2])
        }
        h.folders.folder = other
        await capture.finishDetection()
        let outcomes = await batch.value
        #expect(outcomes == [.copied], "\(outcomes)")
        #expect(h.files.uniqueSaves.isEmpty, "no save, and none redirected to the newly chosen folder")
        let copy = try #require(h.clipboard.writes.first)
        #expect(SecretExport.secretPixels(in: try capture.exportedPixels(copy), MaskingCapture.secret, green: 0) == 0)

        // Automatic save turned on during masking does not join a batch planned without it.
        let late = try await MaskingCapture { $0.settings.update { $0.autoCopy = true } }
        defer { late.model.close() }
        let latePlan = late.harness.export.automaticExportPlan()
        let lateBatch = Task { await late.model.runAutomaticExports(latePlan) }
        await late.waitForDetection()
        enableCopyAndSave(late.harness)
        await late.finishDetection()
        #expect(await lateBatch.value == [.copied])
        #expect(late.harness.files.uniqueSaves.isEmpty)
    }

    private func enableEverything(_ h: EditorHarness) {
        enableCopyAndSave(h)
        h.settings.update {
            $0.githubUpload = GitHubUploadPreferences(
                destination: GitHubDestination(owner: "synthetic", repository: "private-fixtures"), automatic: true)
        }
    }

    @Test("An Undo queued between the masks landing and the batch resuming exports nothing unmasked")
    func undoBeforeTheBatchResumes() async throws {
        let upload = MaskingUpload()
        let capture = try await MaskingCapture(upload: upload, configure: enableEverything)
        let (h, model) = (capture.harness, capture.model)
        defer { model.close() }
        let plan = h.export.automaticExportPlan()
        #expect(plan.copy && plan.save != nil && plan.upload != nil)
        // Waiters resume in order on the main actor, so this Undo runs after the masks land and
        // before the batch continues.
        let undo = Task {
            _ = await model.autoRedactionSettled()
            model.undo()
        }
        await waitFor("undo waits") { model.autoRedactionWaiters.count == 1 }
        let batch = Task { await model.runAutomaticExports(plan) }
        await waitFor("batch waits") { model.autoRedactionWaiters.count == 2 }
        await capture.waitForDetection()
        await capture.finishDetection()
        await undo.value
        let outcomes = await batch.value
        #expect(model.document.masks.isEmpty, "the person's Undo removed the masks")
        #expect(outcomes.allSatisfy { !$0.didWrite }, "\(outcomes)")
        #expect(h.clipboard.writes.isEmpty && h.files.uniqueSaves.isEmpty && upload.written.isEmpty)
        for snapshot in upload.received { #expect(try capture.secretPixels(snapshot) == 0) }
    }

    @Test("The waiting batch uploads the masked capture")
    func automaticUploadUsesTheMaskedSession() async throws {
        let upload = MaskingUpload()
        let capture = try await MaskingCapture(upload: upload, configure: enableEverything)
        defer { capture.model.close() }
        let plan = capture.harness.export.automaticExportPlan()
        let batch = Task { await capture.model.runAutomaticExports(plan) }
        await capture.waitForDetection()
        await capture.finishDetection()
        let outcomes = await batch.value
        #expect(outcomes.count == 3 && outcomes.allSatisfy(\.didWrite), "\(outcomes)")
        let sent = try #require(upload.written.first)
        #expect(try capture.secretPixels(sent) == 0)
        #expect(sent.revision == capture.model.session.revision && capture.model.document.masks.count == 1)
    }

    @Test("A continuous change begun while masking runs cannot fold the masks into its undo step")
    func continuousChangeDuringMasking() async throws {
        let capture = try await MaskingCapture()
        let model = capture.model
        defer { model.close() }
        let padding = model.document.presentation.padding
        await capture.waitForDetection()
        let change = model.beginContinuousChange()
        model.setPadding(10)
        await capture.finishDetection()
        #expect(model.document.masks.count == 1)
        model.setPadding(24)
        model.endContinuousChange(change)
        model.undo()
        #expect(model.document.masks.count == 1, "undoing the padding change keeps the automatic masks")
        #expect(model.document.presentation.padding == padding)
    }

    @Test("A session change during detection makes its result stale: masking fails closed", arguments: [true, false])
    func staleDetectionResult(found: Bool) async throws {
        let capture = try await MaskingCapture { $0.sensitiveText.regions = found ? [MaskingCapture.region] : [] }
        let model = capture.model
        defer { model.close() }
        await capture.waitForDetection()
        // The editor refuses every change while masking runs; this stands for any path that would not.
        try model.session.addSecureMask(covering: Rect(x: 300, y: 200, width: 40, height: 40))
        let changed = model.document
        await capture.finishDetection()
        #expect(model.autoRedaction == .failed && model.notice == .maskingFailed)
        #expect(model.document == changed, "no automatic mask landed on a document the result was not for")
    }

    @Test("An editor released without closing cancels its detection")
    func releasedEditorCancelsDetection() async throws {
        let harness: EditorHarness
        weak var released: EditorModel?
        do {
            let capture = try await MaskingCapture()
            harness = capture.harness
            released = capture.model
            await capture.waitForDetection()
        }
        #expect(released == nil)
        harness.sensitiveText.pending?.resolve(())
        await drain()
        #expect(harness.sensitiveText.observedCancellation)
    }

    @Test("Only the person's Undo brings the secret back into exported bytes")
    func undoRevealsTheSecretInExports() async throws {
        let capture = try await MaskingCapture()
        let (h, model) = (capture.harness, capture.model)
        defer { model.close() }
        await capture.waitForDetection()
        await capture.finishDetection()
        await model.settlePreviews()
        #expect(await model.export(.copy) == .copied)
        #expect(try capture.secretPixels(try #require(h.clipboard.writes.last)) == 0)
        model.undo()
        await model.settlePreviews()
        #expect(await model.export(.copy) == .copied)
        #expect(try capture.secretPixels(try #require(h.clipboard.writes.last)) > 0, "positive control")
    }

    enum Failure: String, CaseIterable { case error, cancellation, deadline }

    @Test("Error, cancellation and deadline fail closed", arguments: Failure.allCases)
    func failsClosed(_ failure: Failure) async throws {
        let capture = try await MaskingCapture(configure: enableCopyAndSave)
        let (h, model) = (capture.harness, capture.model)
        defer { model.close() }
        let plan = h.export.automaticExportPlan()
        let batch = Task { await model.runAutomaticExports(plan) }
        await capture.waitForDetection()
        switch failure {
        case .error:
            h.sensitiveText.error = TestError()
            await capture.finishDetection()
        case .cancellation:
            h.sensitiveText.error = CancellationError()
            await capture.finishDetection()
        case .deadline:
            await waitFor("deadline armed") { h.clock.pendingSleepCount == 1 }
            #expect(h.clock.sleepRequests == [EditorModel.autoRedactionDeadline])
            h.clock.advance(bySeconds: Double(EditorModel.autoRedactionDeadline.components.seconds))
            await waitFor("masking settled") { model.autoRedaction != .pending }
        }
        #expect(model.autoRedaction == .failed)
        #expect(model.notice == .maskingFailed)
        #expect(model.document.masks.isEmpty && !model.canUndo)
        #expect(await batch.value == [.failed(.maskingUnfinished)])
        #expect(h.exporter.snapshotCount == 0 && h.clipboard.writes.isEmpty && h.files.uniqueSaves.isEmpty)
        if failure == .deadline {
            // A result that arrives after the deadline is ignored.
            h.sensitiveText.pending?.resolve(())
            await drain()
            #expect(model.document.masks.isEmpty && h.sensitiveText.observedCancellation)
        }
        await h.settle()
        #expect(model.baseImage != nil, "the canvas shows the capture")
        #expect(await model.export(.copy) == .copied, "manual export is allowed again")
    }

    @Test("Closing the editor while masking cancels detection, skips the batch and releases the asset")
    func closeWhilePending() async throws {
        let capture = try await MaskingCapture(configure: enableCopyAndSave)
        let h = capture.harness
        let plan = h.export.automaticExportPlan()
        let batch = Task { await capture.model.runAutomaticExports(plan) }
        await capture.waitForDetection()
        #expect(await capture.store.count == 1)
        capture.model.close()
        #expect(await batch.value == [.canceled])
        h.sensitiveText.pending?.resolve(())
        await drain()
        #expect(h.sensitiveText.observedCancellation)
        #expect(h.exporter.snapshotCount == 0 && h.clipboard.writes.isEmpty && h.files.uniqueSaves.isEmpty)
        #expect(await capture.store.count == 0)
    }

    @Test("Masks land as one undo step bound to the detected source pixels; Undo removes them all")
    func masksAreOneUndoStep() async throws {
        let regions = [
            MaskingCapture.region, PixelRect(x: 200, y: 120, width: 90, height: 20),
            PixelRect(x: 10, y: 250, width: 140, height: 30),
        ]
        let capture = try await MaskingCapture { $0.sensitiveText.regions = regions }
        let model = capture.model
        defer { model.close() }
        let original = model.document
        await capture.waitForDetection()
        await capture.finishDetection()
        #expect(model.autoRedaction == .done)
        #expect(model.notice == .sensitiveTextMasked(3))
        let asset = try #require(original.layers.first?.assetID)
        #expect(model.document.masks.map(\.sourceRegions) == regions.map { [asset: [$0]] })
        #expect(
            model.document.masks.map(\.outputRect)
                == regions.map {
                    Rect(x: Double($0.x), y: Double($0.y), width: Double($0.width), height: Double($0.height))
                })
        #expect(model.document.masks.allSatisfy { $0.fill.isOpaque })
        #expect(!model.isDirty, "automatic masks are not the person's unexported edits")
        model.undo()
        #expect(model.document == original && !model.canUndo)
        model.redo()
        #expect(model.document.masks.count == 3)
    }

    @Test("Nothing found: masking finishes with no undo step and no notice")
    func nothingFound() async throws {
        let capture = try await MaskingCapture { $0.sensitiveText.regions = [] }
        defer { capture.model.close() }
        await capture.waitForDetection()
        await capture.finishDetection()
        #expect(capture.model.autoRedaction == .done)
        #expect(!capture.model.canUndo && capture.model.notice == nil)
        #expect(capture.harness.sensitiveText.requests.map(\.id) == capture.model.document.layers.map(\.assetID))
    }
}

extension SecretExport {
    /// Exported pixels in `rect` that still show the secret's color (red, or red plus `green`).
    static func secretPixels(in pixels: DecodedPixels, _ rect: FixtureRect, green: UInt8) -> Int {
        var count = 0
        for y in max(0, rect.y)..<min(pixels.height, rect.y + rect.height) {
            for x in max(0, rect.x)..<min(pixels.width, rect.x + rect.width) {
                let p = pixels.pixel(x: x, y: y)
                if p.r > 200 && abs(Int(p.g) - Int(green)) < 40 && p.b < 60 { count += 1 }
            }
        }
        return count
    }
}

/// Hosted CI has no Vision text recognition and declares `RECORTIA_VISION_UNAVAILABLE=1`.
private let visionAvailable = ConditionTrait.enabled(
    if: ProcessInfo.processInfo.environment["RECORTIA_VISION_UNAVAILABLE"] != "1",
    "Vision text recognition is declared unavailable on this runner")

@Suite("Automatic masking with the live detector (FR-06 amendment)")
@MainActor
struct LiveAutoRedactionTests {
    /// Whether every pixel of `rect` has one color: no glyph is visible there.
    private func isUniform(_ pixels: DecodedPixels, _ rect: CGRect) -> Bool {
        let first = pixels.pixel(x: Int(rect.minX), y: Int(rect.minY))
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let p = pixels.pixel(x: x, y: y)
                if p.r != first.r || p.g != first.g || p.b != first.b { return false }
            }
        }
        return true
    }

    @Test("Vision finds the e-mail address, the masks land, and only Undo shows it in exported bytes", visionAvailable)
    func liveDetectorMasksExportedBytes() async throws {
        let scale = 2
        let screen = try SensitiveScreen.renderItem(
            "ana.souza@example.com", kind: .email, widthPoints: 600, heightPoints: 200, scale: scale, pointSize: 14,
            x: 60, top: 80)
        let item = try #require(screen.planted.first).rect
        let store = ImageStore()
        let info = await store.insert(
            try ImageDecoder.canonicalize(screen.image),
            origin: .captured(
                EditorFixtures.captureGeometry(
                    width: screen.image.width, height: screen.image.height, scale: Double(scale))))
        let h = EditorHarness()
        h.assets.store = store
        h.exporter.pipeline = ExportPipeline(renderer: PrivacyRenderer(store: store))
        let environment = EditorEnvironment(
            renderer: h.renderer, export: h.export, folders: h.folders, textRecognition: h.recognizer,
            qrDecoder: h.qr, sensitiveText: LiveSensitiveText(store: store), assets: h.assets, input: h.input,
            pins: h.pins, textClipboard: h.textClipboard, links: h.links, settings: h.settings, clock: h.clock)
        let model = EditorModel(
            session: DocumentSession(document: Document(asset: info)), environment: environment, autoRedacts: true)
        defer { model.close() }
        // The deadline runs on the harness's manual clock, so only Vision decides here.
        let clock = ContinuousClock()
        let start = clock.now
        while model.isMaskingPending, clock.now - start < .seconds(60) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.autoRedaction == .done)
        let mask = try #require(model.document.masks.first)
        #expect(model.document.masks.count == 1)
        let covered = CGRect(
            x: mask.outputRect.minX, y: mask.outputRect.minY, width: mask.outputRect.width,
            height: mask.outputRect.height)
        #expect(covered.contains(item), "\(covered) does not cover \(item)")

        await model.settlePreviews()
        #expect(await model.export(.copy) == .copied)
        let masked = try ContainerInspector.decodePixels(try #require(h.clipboard.writes.last).bytes)
        #expect(isUniform(masked, item), "the exported address shows no glyph")
        model.undo()
        await model.settlePreviews()
        #expect(await model.export(.copy) == .copied)
        let unmasked = try ContainerInspector.decodePixels(try #require(h.clipboard.writes.last).bytes)
        #expect(!isUniform(unmasked, item), "positive control: after Undo the address is exported")
    }
}
