import CoreGraphics
import Domain
import Foundation
import Imaging
import RecortiaFixtures
import Testing

@testable import Features

@MainActor
struct QuickActionsCopyTextTests {
    @Test("Copy Text recognizes only the normal-resolution sanitized image and keeps the capture available")
    func sanitizedRecognitionAndTimer() async throws {
        let source = try ChartFixture.photographic(width: 960, height: 720)
        let store = ImageStore()
        let asset = await store.insert(try ImageDecoder.decode(ContainerCrafting.pngData(source)), origin: .pasted)
        var session = DocumentSession(document: Document(asset: asset))
        try session.addSecureMask(covering: Rect(x: 300, y: 200, width: 360, height: 320))
        let text = RecordingRecognition()
        text.pending = Pending<Void>()
        let h = QuickActionsHarness(renderService: QuickOCRRenderer(store: store), textRecognition: text)
        h.settings.update {
            $0.primaryRecognitionLanguage = Locale.Language(identifier: "pt-BR").maximalIdentifier
            $0.ocrTextMode = .normalizedWhitespace
        }
        await h.shown(session)
        let preview = try #require(h.model.capture?.preview)
        #expect(preview.width < source.width && h.textClipboard.writes.isEmpty)
        let copy = Task { await h.model.copyText() }
        defer { text.pending?.resolve(()) }
        await waitFor("OCR waits after receiving the render") { text.pending?.waiterCount == 1 }
        let image = try #require(text.image)
        let actual = try ContainerInspector.pixels(of: image)
        let original = try ContainerInspector.pixels(of: source)
        #expect(actual.width == original.width && actual.height == original.height)
        #expect(actual.pixel(x: 480, y: 360) == ChartFixture.Color(0, 0, 0, 255))
        #expect(original.pixel(x: 480, y: 360) != actual.pixel(x: 480, y: 360))
        #expect(actual.pixel(x: 100, y: 360) == original.pixel(x: 100, y: 360))
        #expect(text.requestedLanguages.map { $0.languageCode?.identifier } == ["pt", "en"])
        #expect(await h.model.copy() == .rejectedBusy)
        h.clock.advance(bySeconds: 60)
        await drain()
        #expect(h.model.isShown && h.model.isActing && h.textClipboard.writes.isEmpty)
        text.pending?.resolve(())
        #expect(await copy.value == .copied)
        #expect(h.textClipboard.writes == ["Relatório trimestral Revisão concluída"])
        #expect(h.model.isShown && !h.model.isActing)
        #expect(h.exporter.snapshotCount == 0 && h.files.saves.isEmpty && h.upload.uploaded.isEmpty)
        await waitFor("the timeout resumes after Copy Text") { h.clock.pendingSleepCount == 1 }
        h.clock.advance(bySeconds: 8)
        await waitFor("the idle thumbnail expires") { h.model.capture == nil }
    }

    enum Interruption: CaseIterable {
        case selection, selectionDuringRender, dismiss, replacement, openEditor, copyLink
    }

    @Test("A retired Copy Text does not write or overlap a new OCR request", arguments: Interruption.allCases)
    func staleCopy(interruption: Interruption) async throws {
        let text = RecordingRecognition()
        let delayed = Pending<Void>()
        text.pending = delayed
        let h = QuickActionsHarness(textRecognition: text)
        let link = QuickUpload.link(for: h.session.document.id)
        if interruption == .copyLink {
            h.settings.update {
                $0.githubUpload = GitHubUploadPreferences(
                    destination: GitHubDestination(owner: "fixture", repository: "captures"), automatic: true)
            }
            #expect(await h.model.present(h.session, after: h.export.automaticExportPlan()) == [.uploaded(link)])
        } else {
            await h.shown()
        }
        let delayedRender = Pending<Result<CGImage, ExportServiceError>>()
        let blocksRender = interruption == .selectionDuringRender
        let lateImage = try #require(makeImage())
        if blocksRender { h.renderer.pending = delayedRender }
        let first = Task { await h.model.copyText() }
        if blocksRender {
            await waitFor("the original render is pending") { delayedRender.waiterCount == 1 }
            h.renderer.pending = nil
        } else {
            await waitFor("the original OCR request is pending") { delayed.waiterCount == 1 }
        }
        switch interruption {
        case .selection, .selectionDuringRender:
            h.model.suspendForCapture(keepingVisiblePreview: false)
        case .dismiss:
            h.model.dismiss()
        case .replacement:
            await h.shown(TestFixtures.session())
        case .openEditor:
            h.model.openInEditor()
        case .copyLink:
            #expect(h.model.copyLink())
        }
        if !h.model.isShown { await h.shown() }
        #expect(!h.model.isActing)
        text.pending = nil
        #expect(await h.model.copyText() == .rejectedBusy)
        delayed.resolve(())
        delayedRender.resolve(.success(lateImage))
        #expect(await first.value == .canceled)
        if blocksRender { #expect(text.image == nil) }
        let previous = interruption == .copyLink ? [link.absoluteString] : []
        #expect(h.textClipboard.writes == previous)
        #expect(await h.model.copyText() == .copied)
        #expect(h.textClipboard.writes.count == previous.count + 1 && h.model.isShown && !h.model.isActing)
    }

    @Test("Render refusal, recognition failure and blank output leave existing clipboard content alone")
    func unusableOCR() async {
        let text = RecordingRecognition()
        let h = QuickActionsHarness(textRecognition: text)
        await h.shown()
        _ = h.textClipboard.writePlainText("previous content")
        h.renderer.shouldFail = true
        #expect(await h.model.copyText() == .recognitionFailed)
        #expect(text.image == nil)
        h.renderer.shouldFail = false
        text.fails = true
        #expect(await h.model.copyText() == .recognitionFailed)
        text.fails = false
        text.lines = ["   ", "\t"]
        #expect(await h.model.copyText() == .noText)
        #expect(h.textClipboard.writes == ["previous content"])
        #expect(h.model.isShown && !h.model.isActing)
    }
}

@MainActor
private final class RecordingRecognition: TextRecognitionService {
    var pending: Pending<Void>?
    var fails = false
    var lines = ["  Relatório  trimestral  ", " Revisão concluída "]
    private(set) var image: CGImage?
    private(set) var requestedLanguages: [Locale.Language] = []

    func supportedLanguages() async -> [Locale.Language] {
        ["en-US", "pt-BR", "fr-FR"].map(Locale.Language.init(identifier:))
    }

    func recognize(_ image: CGImage, languages: [Locale.Language]) async throws -> OCRResult {
        self.image = image
        requestedLanguages = languages
        if let pending { await pending.wait() }
        if fails { throw TestError() }
        return OCRResult(
            lines: lines.map { OCRResult.Line(text: $0, confidence: 1, box: Rect(x: 0, y: 0, width: 1, height: 1)) },
            revision: 3,
            languages: languages.map(\.maximalIdentifier))
    }
}

@MainActor
private final class QuickOCRRenderer: RenderService {
    let renderer: PrivacyRenderer

    init(store: ImageStore) { renderer = PrivacyRenderer(store: store) }

    func render(_ document: Document, scale: Double) async throws -> CGImage {
        try await renderer.render(document, scale: scale)
    }

    func renderBase(_ document: Document, scale: Double) async throws -> CGImage {
        try await renderer.renderBase(document, scale: scale)
    }
}
