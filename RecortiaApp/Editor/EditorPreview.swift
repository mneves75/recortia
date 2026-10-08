#if DEBUG
    import AppKit
    import CoreGraphics
    import Domain
    import Features
    import Imaging
    import MacPlatform
    import SwiftUI

    /// Debug-only editor over a synthetic document and inert services: no screen, clipboard, file,
    /// network, or TCC access, and no real screenshots. Compiled out of Release builds.
    enum EditorPreviewFactory {
        static func model() -> EditorModel {
            let asset = ImageAssetInfo(
                id: AssetID(), pixelSize: PixelSize(width: 640, height: 400), origin: .imported)
            var document = Domain.Document(asset: asset)
            document.annotations = [
                Annotation(
                    kind: .arrow(start: Point(x: 60, y: 320), end: Point(x: 250, y: 190)), style: .default),
                Annotation(kind: .rectangle(Rect(x: 260, y: 120, width: 200, height: 110)), style: .default),
                Annotation(
                    kind: .text(
                        Annotation.TextContent(origin: Point(x: 60, y: 40), string: "Olá, café ☕️", fontSize: 32)),
                    style: Annotation.Style(stroke: .white)),
                Annotation(kind: .step(center: Point(x: 520, y: 300), number: 1), style: .default),
            ]
            document.obfuscations = [
                CosmeticObfuscation(rect: Rect(x: 480, y: 40, width: 120, height: 60), style: .blur(radius: 12))
            ]
            var session = DocumentSession(document: document)
            // A mask over plain pixels always maps; `try?` keeps the preview free of force-tries.
            _ = try? session.addSecureMask(covering: Rect(x: 300, y: 300, width: 140, height: 40))
            session.markSaved()
            return EditorModel(session: session, environment: environment())
        }

        static func environment() -> EditorEnvironment {
            let settings = PreviewSupport.settings()
            let renderer = PreviewEditorRenderer()
            let export = ExportCoordinator(
                exporter: PreviewEditorExporter(), clipboard: PreviewEditorSink(), files: PreviewEditorSink(),
                drag: PreviewEditorSink(), folders: PreviewEditorSink(), clock: PreviewEditorClock(), settings: settings
            )
            return EditorEnvironment(
                renderer: renderer, export: export, folders: PreviewEditorSink(),
                textRecognition: PreviewTextRecognition(), qrDecoder: PreviewEditorQR(), assets: PreviewEditorAssets(),
                input: PreviewEditorAssets(), pins: PinsModel(renderer: renderer, settings: settings, export: export),
                textClipboard: PreviewEditorSink(), links: PreviewEditorSink(), settings: settings)
        }

        static func rootView(for model: EditorModel, actions: any EditorWindowActions) -> some View {
            let canvas = EditorCanvasView(model: model)
            canvas.actions = actions
            return EditorRootView(model: model, canvas: canvas, actions: actions)
        }
    }

    /// Inert window actions for previews.
    final class PreviewEditorActions: EditorWindowActions {
        func copyImage() {}
        func saveImage() {}
        func saveToPreferredFolder() {}
        func pin() {}
        func addImageFromFile() {}
        func pasteImageLayer() {}
        func commitPendingText() {}
        func dragOut() {}
    }

    struct PreviewUnavailable: Error {}

    /// Renders a synthetic gradient the size of the canvas instead of real pixels.
    final class PreviewEditorRenderer: RenderService {
        func render(_ document: Domain.Document, scale: Double) async throws -> CGImage {
            try image(for: document)
        }

        func renderBase(_ document: Domain.Document, scale: Double) async throws -> CGImage {
            try image(for: document)
        }

        private func image(for document: Domain.Document) throws -> CGImage {
            let width = max(1, Int(document.canvasSize.width)), height = max(1, Int(document.canvasSize.height))
            guard let image = PreviewSupport.image(width: width, height: height) else { throw PreviewUnavailable() }
            return image
        }
    }

    final class PreviewEditorExporter: ExportService {
        func makeSnapshot(of session: DocumentSession, options: ExportOptions, date: Date)
            async throws(ExportServiceError) -> ShareSnapshot
        {
            throw ExportServiceError(.renderFailed)
        }

        func makeSnapshot(
            ofPinned image: CGImage, exportID: DocumentID, privacyEpoch: UInt64, options: ExportOptions, date: Date
        ) async throws(ExportServiceError) -> ShareSnapshot {
            throw ExportServiceError(.renderFailed)
        }
    }

    /// Every sink refuses: previews never write anywhere.
    final class PreviewEditorSink: ClipboardSinkService, FileSinkService, DragSinkService, SaveFolderService,
        TextClipboardService, ExternalLinkOpenerService
    {
        func write(_ snapshot: ShareSnapshot) throws(SinkError) { throw .clipboardWriteFailed }
        func save(_ snapshot: ShareSnapshot, to url: URL, overwrite: Bool) async throws(SinkError) -> URL {
            throw .accessDenied
        }
        func saveUnique(_ snapshot: ShareSnapshot, in folder: URL) async throws(SinkError) -> URL {
            throw .accessDenied
        }
        func deliver(_ snapshot: ShareSnapshot, lease: ExportLease) async throws(SinkError) -> DragDeliveryOutcome {
            .canceledByUser
        }
        func dismiss() {}
        func resolveFolder(bookmark: Data) -> URL? { nil }
        func writePlainText(_ text: String) -> Bool { false }
        func open(_ url: URL) -> Bool { false }
    }

    final class PreviewEditorClock: FeatureClock {
        func now() -> Date { Date(timeIntervalSince1970: 1_790_000_000) }
        func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
    }

    final class PreviewEditorQR: QRDecodingService {
        func decode(_ image: CGImage) async throws -> [QRPayload] { [] }
    }

    final class PreviewEditorAssets: ImageAssetService, ImageInputService {
        func importImage(_ data: Data, origin: AssetOrigin) async throws(ImportError) -> ImageAssetInfo {
            throw .unreadable
        }
        func registerCapture(_ image: CGImage, geometry: CaptureGeometry) async throws(ImportError) -> ImageAssetInfo {
            throw .unreadable
        }
        func registerStitched(_ image: CGImage, partialReason: ScrollPartialReason?) async throws(ImportError)
            -> ImageAssetInfo
        {
            throw .unreadable
        }
        func release(_ id: AssetID) {}
        func readFile(at url: URL) async throws(ImportError) -> Data { throw .unreadable }
        func readPasteboardImage() -> Data? { nil }
    }

    #Preview("Editor") {
        EditorPreviewFactory.rootView(for: EditorPreviewFactory.model(), actions: PreviewEditorActions())
            .frame(width: 1180, height: 720)
    }
#endif
