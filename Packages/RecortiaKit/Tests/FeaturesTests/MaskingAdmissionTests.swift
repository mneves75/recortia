import CoreGraphics
import Domain
import Foundation
import Imaging
import Testing

@testable import Features

/// R-4: while automatic masks are pending, every public `EditorModel` function either goes through
/// the one admission point and is refused, or touches nothing the masks protect. The capture
/// carries one object of each kind, undo and redo history and a left-over selection, so each
/// refused command has something it would change if its admission were missing.
@Suite("Masking admission: every editor entry point while masks are pending (R-4)")
@MainActor
struct MaskingAdmissionTests {
    enum Expectation {
        /// Refused without a notice: pointer, selection, history and edit traffic.
        case refused
        /// Refused with `.maskingInProgress`: a command the person gave by name.
        case explains
        /// View state, preferences, results that cannot exist yet, or callbacks: the document,
        /// history, selection and sinks stay as they were, and its own notices are not judged.
        case inert
    }

    struct Step {
        let name: String
        let expectation: Expectation
        let run: @MainActor () async throws -> Void
    }

    /// Everything the masks protect, plus the sinks pixels or text could leave through.
    struct Observed: Equatable {
        var document: Document
        var revision: UInt64
        var undoCount: Int
        var canRedo: Bool
        var isGrouping: Bool
        var privacyEpoch: UInt64
        var selection: Set<EditorItemID>
        var textEditing: EditorTextEditing?
        var showsOutputPreview: Bool
        var heldPixels: [Bool]
        var results: [String]
        var sinks: [Int]

        @MainActor
        init(_ model: EditorModel, _ h: EditorHarness) {
            let id = model.session.document.id
            document = model.session.document
            revision = model.session.revision
            undoCount = model.session.undoCount
            canRedo = model.session.canRedo
            isGrouping = model.session.isGrouping
            privacyEpoch = model.session.privacyEpoch
            selection = model.selection
            textEditing = model.textEditing
            showsOutputPreview = model.showsOutputPreview
            heldPixels = [
                model.baseImage != nil, model.outputPreview != nil, model.inspection != nil, model.pickedColor != nil,
            ]
            results = ["\(model.recognition)", "\(model.qr)"]
            sinks = [
                h.exporter.snapshotCount, h.clipboard.writes.count, h.files.saves.count, h.files.uniqueSaves.count,
                h.drag.deliveries.count, h.pins.pins.count, h.textClipboard.writes.count, h.links.opened.count,
                h.renderer.baseRenders.count { $0.id == id }, h.renderer.fullRenders.count { $0.id == id },
                h.recognizer.recognizedSizes.count, h.qr.decodeCount, h.input.pasteboardReads,
                h.input.fileReads.count, model.environment.imageImporter.isImporting ? 1 : 0,
            ]
        }

        func changes(from other: Observed) -> [String] {
            var changed: [String] = []
            if document != other.document { changed.append("document") }
            if revision != other.revision || undoCount != other.undoCount || canRedo != other.canRedo
                || isGrouping != other.isGrouping
            {
                changed.append("history")
            }
            if privacyEpoch != other.privacyEpoch { changed.append("privacy epoch") }
            if selection != other.selection { changed.append("selection") }
            if textEditing != other.textEditing { changed.append("text input") }
            if showsOutputPreview != other.showsOutputPreview { changed.append("Output Preview") }
            if heldPixels != other.heldPixels { changed.append("held pixels \(other.heldPixels) -> \(heldPixels)") }
            if results != other.results { changed.append("results \(other.results) -> \(results)") }
            if sinks != other.sinks { changed.append("sinks \(other.sinks) -> \(sinks)") }
            return changed
        }
    }

    /// A document with one layer and one object of each kind, an undo step and a redo step, built
    /// through an unmasked editor's own commands.
    private static func populatedSession() throws -> DocumentSession {
        let builder = EditorHarness()
        defer { builder.model.close() }
        let model = builder.model
        for (tool, a, b) in [
            (EditorTool.rectangle, (20.0, 20.0), (80.0, 60.0)), (.arrow, (100, 20), (180, 60)),
            (.redact, (20, 100), (80, 140)), (.blur, (100, 100), (160, 140)), (.spotlight, (200, 100), (260, 140)),
            (.magnifier, (300, 100), (340, 140)), (.ellipse, (20, 200), (80, 260)),
        ] {
            model.selectTool(tool)
            builder.drag(a, b)
        }
        model.selectTool(.step)
        builder.click(300, 40)
        model.selectTool(.text)
        builder.click(200, 220)
        model.commitTextEditing("Note")
        let arrow = try #require(model.document.annotations.first { if case .arrow = $0.kind { true } else { false } })
        model.select(.annotation(arrow.id))
        #expect(model.setArrowCurved(true))
        model.selectTool(.line)
        builder.drag((200, 260), (260, 280))
        model.undo()  // leaves a redo step
        let d = model.document
        #expect(d.layers.count == 1 && d.masks.count == 1 && d.obfuscations.count == 1 && d.callouts.count == 2)
        #expect(d.annotations.count == 5 && model.session.canUndo && model.session.canRedo)
        #expect(!model.session.isGrouping)
        return model.session
    }

    @Test("While masks are pending every public entry point is refused or touches nothing they protect")
    func everyEntryPointWhilePending() async throws {
        let h = EditorHarness()
        h.sensitiveText.pending = Pending<Void>()
        h.settings.update { $0.autoCopy = true }
        let model = EditorModel(
            session: try Self.populatedSession(), environment: h.model.environment, autoRedacts: true)
        await waitFor("detection started") { h.sensitiveText.pending?.waiterCount == 1 }
        #expect(model.isMaskingPending)
        // A selection cannot form while masks are pending; one left over here gives every
        // selection-driven command something to act on.
        let all = Set(model.allItemIDs)
        model.selection = all
        let d = model.document
        let layer = try #require(d.layers.first).id
        let text = try #require(d.annotations.first { if case .text = $0.kind { true } else { false } }).id
        let arrow = try #require(d.annotations.first { if case .arrow = $0.kind { true } else { false } }).id
        let spotlight = try #require(d.callouts.first { if case .spotlight = $0.kind { true } else { false } }).id
        let magnifier = try #require(d.callouts.first { if case .magnifier = $0.kind { true } else { false } }).id
        let effect = try #require(d.obfuscations.first).id
        let link = try #require(URL(string: "https://example.com"))
        let payload = QRPayload(bytes: Data(link.absoluteString.utf8), string: link.absoluteString, kind: .webURL(link))
        let point = Point<DocumentSpace>(x: 50, y: 40)
        let rect = Rect<DocumentSpace>(x: 10, y: 10, width: 60, height: 40)
        let plan = h.export.automaticExportPlan()
        var batch: Task<[ExportOutcome], Never>?
        let dropped = ImportSource.droppedData(Data([0x89, 0x50, 0x4E, 0x47]))

        let steps: [Step] = [
            // Edits: every one reaches `edit`, the document change path.
            Step(name: "setStrokeColor", expectation: .refused) { model.setStrokeColor(.white) },
            Step(name: "setFillColor", expectation: .refused) { model.setFillColor(.white) },
            Step(name: "setLineWidth", expectation: .refused) { model.setLineWidth(9) },
            Step(name: "setOpacity", expectation: .refused) { model.setOpacity(0.4) },
            Step(name: "setFontSize", expectation: .refused) { model.setFontSize(40) },
            Step(name: "setRedactionFill", expectation: .refused) { model.setRedactionFill(.white) },
            Step(name: "setTextBackgroundColor", expectation: .refused) { model.setTextBackgroundColor(.white) },
            Step(name: "setTextAppearance", expectation: .refused) { #expect(!model.setTextAppearance(.boxed)) },
            Step(name: "setArrowCurved", expectation: .refused) { #expect(!model.setArrowCurved(false)) },
            Step(name: "setArrowHead", expectation: .refused) { #expect(!model.setArrowHead(.double)) },
            Step(name: "setArrowBend", expectation: .refused) {
                model.selection = [.annotation(arrow)]
                defer { model.selection = all }
                #expect(!model.setArrowBend(Point(x: 140, y: 10)))
            },
            Step(name: "deleteSelection", expectation: .refused) { model.deleteSelection() },
            Step(name: "duplicateSelection", expectation: .refused) { model.duplicateSelection() },
            Step(name: "nudgeSelection", expectation: .refused) { model.nudgeSelection(dx: 10, dy: 0) },
            Step(name: "reorderSelection", expectation: .refused) { model.reorderSelection(.back) },
            Step(name: "align", expectation: .refused) { model.align(.left) },
            Step(name: "moveItem", expectation: .refused) { model.moveItem(.annotation(arrow), by: -1) },
            Step(name: "renumberSteps", expectation: .refused) { model.renumberSteps() },
            Step(name: "setFrame", expectation: .refused) { model.setFrame(rect, for: .annotation(arrow)) },
            Step(name: "setMagnifierSource", expectation: .refused) { model.setMagnifierSource(rect, for: magnifier) },
            Step(name: "setCrop", expectation: .refused) { model.setCrop(rect) },
            Step(name: "setResizeScale", expectation: .refused) { model.setResizeScale(2) },
            Step(name: "setLayerOpacity", expectation: .refused) { model.setLayerOpacity(0.5, for: layer) },
            Step(name: "setLayerScale", expectation: .refused) { model.setLayerScale(0.5, for: layer) },
            Step(name: "toggleTransparencyComparison", expectation: .refused) { model.toggleTransparencyComparison() },
            Step(name: "transformImage", expectation: .refused) { model.transformImage(.rotateRight) },
            Step(name: "transformSelectedLayers", expectation: .refused) {
                model.transformSelectedLayers(.flipVertical)
            },
            Step(name: "arrangeSideBySide", expectation: .refused) { model.arrangeSideBySide() },
            Step(name: "fitCanvasToContent", expectation: .refused) { model.fitCanvasToContent() },
            Step(name: "expandCanvas", expectation: .refused) { model.expandCanvas(top: 20, left: 20) },
            Step(name: "setBackground", expectation: .refused) { model.setBackground(.solid(.white)) },
            Step(name: "setPadding", expectation: .refused) { model.setPadding(20) },
            Step(name: "setCornerRadius", expectation: .refused) { model.setCornerRadius(12) },
            Step(name: "setShadow", expectation: .refused) { model.setShadow(Presentation.Shadow()) },
            Step(name: "setAspect", expectation: .refused) { model.setAspect(.square) },
            Step(name: "setBalancesContent", expectation: .refused) { model.setBalancesContent(false) },
            Step(name: "setFramingBorder", expectation: .refused) { model.setFramingBorder(Presentation.Border()) },
            Step(name: "setFramingWatermark", expectation: .refused) {
                #expect(!model.setFramingWatermark(Presentation.Watermark(text: "Draft")))
            },
            Step(name: "setSpotlightDim", expectation: .refused) { model.setSpotlightDim(0.2, for: spotlight) },
            Step(name: "setObfuscationAmount", expectation: .refused) { model.setObfuscationAmount(40, for: effect) },
            Step(name: "commitTextEditing", expectation: .refused) {
                model.textEditing = EditorTextEditing(
                    annotationID: nil, origin: point, initialString: "", fontSize: 20,
                    annotationStyle: model.style.textAnnotationStyle, maxWidth: nil, appearance: .standard)
                model.commitTextEditing("typed while masking")
            },
            // History.
            Step(name: "undo", expectation: .refused) { model.undo() },
            Step(name: "redo", expectation: .refused) { model.redo() },
            Step(name: "beginContinuousChange", expectation: .refused) { _ = model.beginContinuousChange() },
            Step(name: "endContinuousChange", expectation: .inert) {
                model.endContinuousChange()
                model.endContinuousChange(UUID())
            },
            // Selection and pointer input.
            Step(name: "select", expectation: .refused) {
                model.select(.layer(layer))
                model.select(.annotation(text), extending: true)
            },
            Step(name: "setSelection", expectation: .refused) { model.setSelection([.layer(layer)]) },
            Step(name: "selectAll", expectation: .refused) { model.selectAll() },
            Step(name: "clearSelection", expectation: .refused) { model.clearSelection() },
            Step(name: "beginEditingText", expectation: .refused) { model.beginEditingText(text) },
            Step(name: "pointerDown", expectation: .refused) {
                for tool in EditorTool.allCases {
                    model.selectTool(tool)
                    model.pointerDown(at: point)
                    model.pointerDragged(to: Point(x: 120, y: 90))
                    model.pointerUp(at: Point(x: 120, y: 90))
                }
            },
            Step(name: "pointerDragged", expectation: .refused) { model.pointerDragged(to: point) },
            Step(name: "pointerUp", expectation: .refused) { model.pointerUp(at: point) },
            Step(name: "pointerMoved", expectation: .refused) {
                model.selectTool(.loupe)
                model.pointerMoved(to: point)
            },
            // Pixel tools read the capture.
            Step(name: "inspect", expectation: .refused) { model.inspect(at: point) },
            // Imports.
            Step(name: "addImageLayer", expectation: .explains) {
                #expect(!(await model.addImageLayer(from: dropped)))
                model.dismissNotice()
                #expect(!(await model.addImageLayer(readSource: { dropped })))
            },
            Step(name: "admitDroppedImage", expectation: .explains) {
                #expect(model.admitDroppedImage(readSource: { dropped }) == nil)
            },
            // Output: export, pin, Output Preview and recognition.
            Step(name: "export", expectation: .explains) {
                let requests: [EditorExportRequest] = [
                    .copy, .drag, .print, .saveToPreferredFolder,
                    .save(
                        URL(fileURLWithPath: "/tmp/recortia-tests/admission.png"), format: .fixed(.png),
                        replacing: URL(fileURLWithPath: "/tmp/recortia-tests/admission.png")),
                ]
                for request in requests {
                    model.dismissNotice()
                    #expect(await model.export(request) == .failed(.maskingUnfinished))
                }
            },
            Step(name: "pin", expectation: .explains) { await model.pin() },
            Step(name: "setShowsOutputPreview", expectation: .explains) {
                model.setShowsOutputPreview(false)
                model.setShowsOutputPreview(true)
            },
            Step(name: "recognizeText", expectation: .explains) {
                await model.recognizeText()
                model.dismissNotice()
                await model.recognizeText(in: rect)
            },
            Step(name: "decodeQR", expectation: .explains) { await model.decodeQR() },
            // The capture's automatic batch waits for the masks (checked after closing).
            Step(name: "runAutomaticExports", expectation: .inert) {
                batch = Task { await model.runAutomaticExports(plan) }
            },
            // No result exists while masks are pending, so nothing can be copied or opened.
            Step(name: "recognizedText", expectation: .inert) { #expect(model.recognizedText(mode: .raw) == nil) },
            Step(name: "copyRecognizedText", expectation: .inert) { #expect(!model.copyRecognizedText(mode: .raw)) },
            Step(name: "canOpenQRPayload", expectation: .inert) { #expect(!model.canOpenQRPayload(at: 0)) },
            Step(name: "copyQRPayload", expectation: .inert) { #expect(!model.copyQRPayload(at: 0)) },
            Step(name: "openQRPayload", expectation: .inert) { #expect(!model.openQRPayload(payload, at: 0)) },
            Step(name: "copyPickedColor", expectation: .inert) { #expect(!model.copyPickedColor()) },
            Step(name: "usePickedColor", expectation: .inert) { #expect(!model.usePickedColor(as: .text)) },
            Step(name: "loupe", expectation: .inert) { #expect(model.loupe() == nil) },
            Step(name: "clearRecognition", expectation: .inert) { model.clearRecognition() },
            Step(name: "clearQR", expectation: .inert) { model.clearQR() },
            // Reads of the document model, not of its pixels.
            Step(name: "frame", expectation: .inert) { _ = model.frame(of: .layer(layer)) },
            Step(name: "kind", expectation: .inert) { _ = model.kind(of: .layer(layer)) },
            Step(name: "item", expectation: .inert) { _ = model.item(at: point) },
            // Tools, future-object defaults, preferences and the viewport.
            Step(name: "selectTool", expectation: .inert) { model.selectTool(.rectangle) },
            Step(name: "setRedactsTextOnly", expectation: .inert) { model.setRedactsTextOnly(true) },
            Step(name: "setColorSampleSize", expectation: .inert) { model.setColorSampleSize(.fiveByFive) },
            Step(name: "setStrokeSmoothing", expectation: .inert) { model.setStrokeSmoothing(false) },
            Step(name: "setSamplesDarkestPixel", expectation: .inert) { model.setSamplesDarkestPixel(true) },
            Step(name: "setCropAspect", expectation: .inert) { model.setCropAspect(.sixteenByNine) },
            Step(name: "saveCurrentStrokeColor", expectation: .inert) { model.saveCurrentStrokeColor() },
            Step(name: "saveDefaultFraming", expectation: .inert) { model.saveDefaultFraming() },
            Step(name: "resetDefaultFraming", expectation: .inert) { model.resetDefaultFraming() },
            Step(name: "applySavedColor", expectation: .inert) { model.applySavedColor(model.style.stroke) },
            Step(name: "removeSavedColor", expectation: .inert) { model.removeSavedColor(model.style.stroke) },
            Step(name: "clearRuler", expectation: .inert) { model.clearRuler() },
            Step(name: "cancelTextEditing", expectation: .inert) { model.cancelTextEditing() },
            Step(name: "cancelGesture", expectation: .inert) { model.cancelGesture() },
            Step(name: "setViewportSize", expectation: .inert) {
                model.setViewportSize(Size(width: 800, height: 600), backingScale: 2)
            },
            Step(name: "setViewport", expectation: .inert) { model.setViewport(model.viewport) },
            Step(name: "zoomToFit", expectation: .inert) { model.zoomToFit() },
            Step(name: "zoomToActualPixels", expectation: .inert) { model.zoomToActualPixels() },
            Step(name: "zoomIn", expectation: .inert) { model.zoomIn() },
            Step(name: "zoomOut", expectation: .inert) { model.zoomOut() },
            Step(name: "setZoom", expectation: .inert) { model.setZoom(2) },
            Step(name: "zoomToSelection", expectation: .inert) { model.zoomToSelection() },
            Step(name: "pan", expectation: .inert) { model.pan(dx: 10, dy: 10) },
            Step(name: "scrollWheel", expectation: .inert) {
                model.scrollWheel(
                    EditorScrollWheel(deltaX: 3, deltaY: 5, isPrecise: true, isMouseWheel: true), at: .zero)
            },
            // Callbacks from the canvas and the automatic batch, and the notice slot.
            Step(name: "reportCanvasDrawSucceeded", expectation: .inert) { model.reportCanvasDrawSucceeded() },
            Step(name: "reportCanvasRenderFailure", expectation: .inert) { model.reportCanvasRenderFailure() },
            Step(name: "reportAutomaticExport", expectation: .inert) { model.reportAutomaticExport(.copied) },
            Step(name: "dismissNotice", expectation: .inert) { model.dismissNotice() },
            Step(name: "cancelExport", expectation: .inert) { model.cancelExport() },
        ]

        for step in steps {
            model.dismissNotice()
            let before = Observed(model, h)
            try await step.run()
            await drain()
            let changed = Observed(model, h).changes(from: before)
            #expect(changed.isEmpty, "\(step.name) while masks are pending changed: \(changed)")
            #expect(model.isMaskingPending, "\(step.name) settled the masking")
            switch step.expectation {
            case .refused: #expect(model.notice == nil, "\(step.name) posted \(String(describing: model.notice))")
            case .explains: #expect(model.notice == .maskingInProgress, "\(step.name) did not explain the wait")
            case .inert: break
            }
        }
        #expect(!model.canStartExport && !model.canArrangeSelection)

        // Closing while pending cancels the masking and the batch that waited for it.
        let beforeClose = Observed(model, h)
        model.close()
        let outcomes = await batch?.value
        #expect(outcomes == [.canceled], "\(String(describing: outcomes))")
        #expect(Observed(model, h).sinks == beforeClose.sinks, "closing exported nothing")

        let driven = Set(steps.map(\.name)).union(["close"])
        let declared = try Self.publicFunctions()
        #expect(declared.subtracting(driven).isEmpty, "not driven while pending: \(declared.subtracting(driven))")
        #expect(driven.subtracting(declared).isEmpty, "no longer public: \(driven.subtracting(declared))")
    }

    // MARK: - Inventory

    static let publicFunction = try? NSRegularExpression(
        pattern: #"(?m)^[ \t]*(?:@\w+[ \t]+)*public[ \t]+(?:(?:nonisolated|final|override)[ \t]+)*func[ \t]+(\w+)"#)

    private static var featuresSources: URL {
        // .../Packages/RecortiaKit/Tests/FeaturesTests/<this file>
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/Features")
    }

    private static func editorModelSources() throws -> [(name: String, source: String)] {
        let files = try FileManager.default.contentsOfDirectory(at: featuresSources, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("EditorModel") && $0.pathExtension == "swift" }
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    static func functionNames(in source: String) -> Set<String> {
        guard let publicFunction else { return [] }
        let matches = publicFunction.matches(in: source, range: NSRange(source.startIndex..., in: source))
        return Set(matches.compactMap { Range($0.range(at: 1), in: source).map { String(source[$0]) } })
    }

    private static func publicFunctions() throws -> Set<String> {
        let sources = try editorModelSources()
        #expect(sources.count >= 10, "found too few EditorModel files under \(featuresSources.path)")
        return sources.reduce(into: Set<String>()) { $0.formUnion(functionNames(in: $1.source)) }
    }

    @Test("The inventory sees public functions and skips static ones (planted control)")
    func inventoryControl() {
        #expect(Self.publicFunction != nil)
        let planted = """
                public func plain() {}
                @discardableResult public func attributed() -> Bool { true }
                public static func helper() {}
                func internalOne() {}
            """
        #expect(Self.functionNames(in: planted) == ["plain", "attributed"])
    }

    @Test("Only the admission point and the masking lifecycle read the pending flag")
    func pendingFlagHasOneReader() throws {
        for (name, source) in try Self.editorModelSources() where name != "EditorModel+AutoRedaction.swift" {
            #expect(!source.contains("isMaskingPending"), "\(name) checks the pending flag instead of admitsAction")
        }
    }
}
