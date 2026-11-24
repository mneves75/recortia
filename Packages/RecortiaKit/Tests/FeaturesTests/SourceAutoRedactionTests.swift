import CoreGraphics
import Domain
import Foundation
import Imaging
import RecortiaFixtures
import Testing

@testable import Features

/// The sanitizing renderer over a real store, so pins show what the person would see.
@MainActor
private final class StoreRenderer: RenderService {
    private let renderer: PrivacyRenderer

    init(store: ImageStore) { renderer = PrivacyRenderer(store: store) }

    func render(_ document: Document, scale: Double) async throws -> CGImage {
        try await renderer.render(document, scale: scale)
    }

    func renderBase(_ document: Document, scale: Double) async throws -> CGImage {
        try await renderer.renderBase(document, scale: scale)
    }
}

/// A new document from one of the sources automatic masking now covers (FR-06 amendment, T2): a
/// scrolling capture accepted from review, or an image opened by Open, Open With, a drop or Paste.
/// The source runs for real (scroll model or import coordinator) over a real `ImageStore`; the
/// editor is opened with the decision the source hands over, as `AppModel` opens it, and its
/// exports and pins go through the real pipeline and sanitizing renderer.
@MainActor
final class MaskingSource {
    enum Source: String, CaseIterable, CustomTestStringConvertible {
        case scrollCapture, openedFile
        var testDescription: String { rawValue }
    }

    /// A tall page with the secret near its bottom, where a stitched capture's last frame lands.
    static let width = 400, height = 1600
    static let secret = FixtureRect(x: 40, y: 1400, width: 120, height: 24)
    static let region = PixelRect(x: 36, y: 1396, width: 128, height: 32)
    static let folder = URL(fileURLWithPath: "/tmp/recortia-tests/source-masking", isDirectory: true)

    let source: Source
    let store = ImageStore()
    let editors = EditorHarness()
    let scroll = ScrollHarness()
    let importer = ImportHarness()
    let pins: PinsModel
    let environment: EditorEnvironment
    private var created = 0

    init(_ source: Source, masking: Bool) {
        self.source = source
        scroll.assets.store = store
        importer.assets.store = store
        editors.assets.store = store
        editors.exporter.pipeline = ExportPipeline(renderer: PrivacyRenderer(store: store))
        editors.sensitiveText.regions = [Self.region]
        editors.sensitiveText.pending = Pending<Void>()
        editors.folders.folder = Self.folder
        let renderer = StoreRenderer(store: store)
        let h = editors
        pins = PinsModel(renderer: renderer, settings: h.settings, export: h.export)
        environment = EditorEnvironment(
            renderer: renderer, export: h.export, folders: h.folders, textRecognition: h.recognizer, qrDecoder: h.qr,
            sensitiveText: h.sensitiveText, assets: h.assets, input: h.input, pins: pins,
            textClipboard: h.textClipboard, links: h.links, settings: h.settings, clock: h.clock)
        setMasking(masking)
    }

    /// The setting in the source's own store, which is what the source reads.
    func setMasking(_ on: Bool) {
        scroll.settings.update { $0.autoRedactsSensitiveText = on }
        importer.settings.update { $0.autoRedactsSensitiveText = on }
    }

    static func image(green: UInt8 = 0) throws -> CGImage {
        try SecretExport.image(width: width, height: height, secrets: [secret], green: green)
    }

    /// Runs the source to its new document. `beforeCreation` runs after the source started and
    /// before its document exists (during scroll review, or while the import decodes).
    func create(beforeCreation: () -> Void = {}) async throws -> (session: DocumentSession, masks: Bool) {
        switch source {
        case .scrollCapture:
            scroll.stitcher.assembled = try Self.image()
            await scroll.startCollecting()
            scroll.frames.deliver()
            await waitFor("frame accepted") { self.scroll.model.acceptedFrames == 1 }
            scroll.model.stop()
            await waitFor("review shown") { self.scroll.model.preview != nil }
            beforeCreation()
            await scroll.model.accept()
            let session = try #require(scroll.accepted.last)
            return (session, try #require(scroll.acceptedMasking.last as Bool?))
        case .openedFile:
            created += 1
            let url = URL(fileURLWithPath: "/tmp/recortia-tests/source-masking-\(created).png")
            importer.input.files[url] = .success(try ContainerCrafting.pngData(Self.image()))
            let pending = Pending<Void>()
            importer.assets.pendingImport = pending
            let opening = Task { await importer.coordinator.importImage(from: .file(url)) }
            await waitFor("import decoding") { pending.waiterCount == 1 }
            beforeCreation()
            importer.assets.pendingImport = nil
            pending.resolve(())
            _ = try await opening.value.get()
            let session = try #require(importer.imported.last)
            return (session, try #require(importer.masking.last as Bool?))
        }
    }

    /// The editor `AppModel` opens for it: `.maskSensitiveText` exactly when the source said so.
    func open(_ document: (session: DocumentSession, masks: Bool)) -> EditorModel {
        EditorModel(session: document.session, environment: environment, autoRedacts: document.masks)
    }

    func waitForDetection(_ count: Int = 1) async {
        await waitFor("detection started") { self.editors.sensitiveText.pending?.waiterCount == count }
    }

    func pixels(_ snapshot: ShareSnapshot) throws -> DecodedPixels {
        try ContainerInspector.decodePixels(snapshot.bytes)
    }

    func secretPixels(_ pixels: DecodedPixels) -> Int {
        SecretExport.secretPixels(in: pixels, Self.secret, green: 0)
    }

    /// Pixels of the planted address that are not the black mask fill: the measure that sees a
    /// leak of any colour, where a colour count would also see look-alikes elsewhere in the image.
    func uncoveredPixels(_ pixels: DecodedPixels) -> Int {
        var count = 0
        for y in Self.secret.y..<min(pixels.height, Self.secret.y + Self.secret.height) {
            for x in Self.secret.x..<min(pixels.width, Self.secret.x + Self.secret.width) {
                let p = pixels.pixel(x: x, y: y)
                if max(p.r, p.g, p.b) > 30 { count += 1 }
            }
        }
        return count
    }
}

@Suite("Automatic masking of scrolling captures and opened images (FR-06 amendment, T2)")
@MainActor
struct SourceAutoRedactionTests {
    @Test(
        "With masking on, the new document opens pending and its masks land as one undo step",
        arguments: MaskingSource.Source.allCases)
    func pendingThenMasked(_ source: MaskingSource.Source) async throws {
        let new = MaskingSource(source, masking: true)
        let document = try await new.create()
        #expect(document.masks, "the source hands over the masking decision")
        let model = new.open(document)
        defer { model.close() }
        let asset = try #require(model.document.layers.first?.assetID)
        await new.waitForDetection()
        #expect(model.isMaskingPending && model.baseImage == nil)
        #expect(new.editors.sensitiveText.requests.map(\.id) == [asset], "detection reads the stored asset")
        #expect(await model.export(.copy) == .failed(.maskingUnfinished))
        #expect(new.editors.clipboard.writes.isEmpty)

        new.editors.sensitiveText.pending?.resolve(())
        await waitFor("masking settled") { model.autoRedaction != .pending }
        #expect(model.autoRedaction == .done)
        #expect(model.document.masks.map(\.sourceRegions) == [[asset: [MaskingSource.region]]])
        #expect(model.notice == .sensitiveTextMasked(1))
        #expect(model.canUndo && !model.isDirty, "one undo step that is not the person's edit")
    }

    enum Failure: String, CaseIterable { case error, deadline }

    @Test(
        "Masking a new document fails closed on error and at the deadline",
        arguments: MaskingSource.Source.allCases, Failure.allCases)
    func failsClosed(_ source: MaskingSource.Source, _ failure: Failure) async throws {
        let new = MaskingSource(source, masking: true)
        let model = new.open(try await new.create())
        defer { model.close() }
        let h = new.editors
        await new.waitForDetection()
        switch failure {
        case .error:
            h.sensitiveText.error = TestError()
            h.sensitiveText.pending?.resolve(())
        case .deadline:
            await waitFor("deadline armed") { h.clock.pendingSleepCount == 1 }
            #expect(h.clock.sleepRequests == [EditorModel.autoRedactionDeadline], "the capture deadline")
            h.clock.advance(bySeconds: Double(EditorModel.autoRedactionDeadline.components.seconds))
        }
        await waitFor("masking settled") { model.autoRedaction != .pending }
        #expect(model.autoRedaction == .failed && model.notice == .maskingFailed)
        #expect(model.document.masks.isEmpty && !model.canUndo)
        if failure == .deadline {
            h.sensitiveText.pending?.resolve(())
            await drain()
            #expect(model.document.masks.isEmpty, "a result after the deadline is ignored")
        }
        await model.settlePreviews()
        #expect(model.baseImage != nil, "the canvas shows the image")
        #expect(await model.export(.copy) == .copied, "manual export is allowed again")
        #expect(new.secretPixels(try new.pixels(try #require(h.clipboard.writes.last))) > 0, "positive control")
    }

    @Test(
        "The setting is read when the document is created: on before then masks, off means no detection",
        arguments: MaskingSource.Source.allCases)
    func decisionAtCreation(_ source: MaskingSource.Source) async throws {
        let off = MaskingSource(source, masking: false)
        let plain = try await off.create()
        #expect(!plain.masks)
        let model = off.open(plain)
        defer { model.close() }
        await model.settlePreviews()
        #expect(model.autoRedaction == .off && off.editors.sensitiveText.requests.isEmpty)
        #expect(model.baseImage != nil)

        // Turned on during review, or while the file decodes: the document is created masked.
        let late = MaskingSource(source, masking: false)
        let masked = try await late.create { late.setMasking(true) }
        #expect(masked.masks)
        let lateModel = late.open(masked)
        defer { lateModel.close() }
        late.setMasking(false)
        await late.waitForDetection()
        #expect(lateModel.isMaskingPending, "a later change applies to the next document")
    }

    @Test(
        "A closed editor's result is ignored and a newer document gets only its own masks",
        arguments: MaskingSource.Source.allCases)
    func staleResults(_ source: MaskingSource.Source) async throws {
        let new = MaskingSource(source, masking: true)
        let first = new.open(try await new.create())
        await new.waitForDetection()
        let firstAsset = try #require(first.document.layers.first?.assetID)
        first.close()
        let second = new.open(try await new.create())
        defer { second.close() }
        let secondAsset = try #require(second.document.layers.first?.assetID)
        await new.waitForDetection(2)
        // The oldest waiter is the closed editor's detection.
        new.editors.sensitiveText.pending?.resolve(())
        await drain()
        #expect(first.document.masks.isEmpty && first.autoRedaction == .failed)
        #expect(second.isMaskingPending, "the closed editor's result did not settle the newer one")
        new.editors.sensitiveText.pending?.resolve(())
        await waitFor("masking settled") { second.autoRedaction != .pending }
        #expect(second.document.masks.map(\.sourceRegions) == [[secondAsset: [MaskingSource.region]]])
        #expect(await new.store.images(for: [firstAsset])[firstAsset] == nil, "closing released the first image")
    }

    /// Measured (decisions.md, T2): a 2880 × 10000 Retina scroll capture swept at 1 pixel per point
    /// took 12.8–16.6 s, past the deadline, and 3.4–4.6 s at its real 2.
    @Test("A scrolling capture is swept at its own pixels per point; an opened image at 1")
    func sweepDensity() async throws {
        let h = ScrollHarness()
        // The harness's target is 400 points wide; the stitched page is 800 pixels wide.
        h.stitcher.assembled = try SecretExport.image(width: 800, height: 1200, secrets: [], green: 0)
        await h.startCollecting()
        h.frames.deliver()
        await waitFor("frame accepted") { h.model.acceptedFrames == 1 }
        h.model.stop()
        await waitFor("review shown") { h.model.preview != nil }
        await h.model.accept()
        let origin = try #require(h.assets.registeredStitched.first?.origin)
        #expect(origin == .scrollCapture(partialReason: nil, pointPixelScale: 2))
        #expect(LiveSensitiveText.pixelsPerPoint(of: origin) == 2)
        #expect(LiveSensitiveText.pixelsPerPoint(of: .imported) == 1)
        #expect(LiveSensitiveText.pixelsPerPoint(of: .pasted) == 1)
    }

    @Test(
        "RED: a masked new document's copy, save, drag and pin bytes cover every pixel of the planted address",
        arguments: MaskingSource.Source.allCases)
    func exportsAreMasked(_ source: MaskingSource.Source) async throws {
        let new = MaskingSource(source, masking: true)
        let model = new.open(try await new.create())
        defer { model.close() }
        let h = new.editors
        await new.waitForDetection()
        h.sensitiveText.pending?.resolve(())
        await waitFor("masking settled") { model.autoRedaction != .pending }
        try #require(model.autoRedaction == .done)
        await model.settlePreviews()

        #expect(await model.export(.copy) == .copied)
        let saveURL = MaskingSource.folder.appending(path: "\(source.rawValue).png")
        #expect(
            await model.export(.save(saveURL, format: .fixed(.png), replacing: saveURL)) == .saved(saveURL))
        #expect(await model.export(.drag) == .dragged)
        await model.pin()
        let pin = try #require(new.pins.pins.first)
        let exported: [(String, DecodedPixels)] = [
            ("copy", try new.pixels(try #require(h.clipboard.writes.last))),
            ("save", try new.pixels(try #require(h.files.saves.last?.snapshot))),
            ("drag", try new.pixels(try #require(h.drag.writtenSnapshots.last))),
            ("pin", try ContainerInspector.decodePixels(try ContainerCrafting.pngData(pin.image))),
        ]
        for (sink, pixels) in exported {
            #expect(pixels.height == MaskingSource.height, "\(sink) exports the whole image")
            #expect(new.secretPixels(pixels) == 0, "\(sink) shows the planted address")
            #expect(new.uncoveredPixels(pixels) == 0, "\(sink) leaves planted pixels unmasked")
        }

        // Positive control: after the person's Undo the same sinks see the address.
        model.undo()
        await model.settlePreviews()
        #expect(await model.export(.copy) == .copied)
        let undone = try new.pixels(try #require(h.clipboard.writes.last))
        #expect(new.secretPixels(undone) > 0)
        #expect(new.uncoveredPixels(undone) > 0)
    }
}
