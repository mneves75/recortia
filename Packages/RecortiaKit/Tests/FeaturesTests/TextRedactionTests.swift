import CoreGraphics
import Domain
import Foundation
import Imaging
import RecortiaFixtures
import Testing

@testable import Features

/// Text-only redaction (A-6): a drawn rectangle is covered at once, and one secure mask per
/// recognized line replaces the cover in the same undo step. Anything short of current lines keeps
/// the whole rectangle covered.
@Suite("Text-only redaction (A-6)")
@MainActor
struct TextRedactionTests {
    static let drawn = Rect<DocumentSpace>(x: 20, y: 20, width: 200, height: 100)
    static let lines = [
        PixelRect(x: 24, y: 26, width: 150, height: 22), PixelRect(x: 24, y: 56, width: 180, height: 22),
        PixelRect(x: 24, y: 86, width: 120, height: 22),
    ]

    /// A harness in Text Only mode whose recognizer waits for the test.
    static func pending(lines: [PixelRect] = Self.lines) -> EditorHarness {
        let h = EditorHarness()
        h.sensitiveText.lines = lines
        h.sensitiveText.pending = Pending<Void>()
        h.model.setRedactsTextOnly(true)
        return h
    }

    static func draw(_ h: EditorHarness) async {
        h.model.selectTool(.redact)
        h.drag((drawn.minX, drawn.minY), (drawn.maxX, drawn.maxY))
        await waitFor("recognition started") { h.sensitiveText.pending?.waiterCount == 1 }
    }

    static func finish(_ h: EditorHarness) async {
        h.sensitiveText.pending?.resolve(())
        await waitFor("recognition settled") { !h.model.isMaskingPending }
    }

    static func asset(_ h: EditorHarness) throws -> AssetID { try #require(h.model.document.layers.first).assetID }

    /// The cover over the whole drawn rectangle, bound to its source pixels.
    static func isCover(_ h: EditorHarness) throws -> Bool {
        let asset = try asset(h)
        let masks = h.model.document.masks
        return masks.count == 1 && masks[0].outputRect == drawn && masks[0].fill.isOpaque
            && masks[0].sourceRegions == [asset: [PixelRect(x: 20, y: 20, width: 200, height: 100)]]
    }

    @Test("Off by default: a redaction covers its rectangle and nothing is recognized")
    func offByDefault() throws {
        let h = EditorHarness()
        #expect(!h.model.redactsTextOnly)
        h.model.selectTool(.redact)
        h.drag((20, 20), (220, 120))
        #expect(try Self.isCover(h) && !h.model.isMaskingPending)
        #expect(h.sensitiveText.lineRequests.isEmpty)
    }

    @Test("Pending: the cover already hides the whole rectangle; then one mask per line lands as one undo step")
    func oneMaskPerLine() async throws {
        let h = Self.pending()
        let model = h.model
        let undoCount = model.session.undoCount
        await Self.draw(h)
        #expect(model.isMaskingPending)
        #expect(try Self.isCover(h), "\(model.document.masks)")
        #expect(h.sensitiveText.lineRequests == [PixelRect(x: 20, y: 20, width: 200, height: 100)])

        await Self.finish(h)
        let asset = try Self.asset(h)
        let masks = model.document.masks
        #expect(masks.map(\.sourceRegions) == Self.lines.map { [asset: [$0]] }, "\(masks)")
        #expect(
            masks.map(\.outputRect)
                == Self.lines.map {
                    Rect(x: Double($0.x), y: Double($0.y), width: Double($0.width), height: Double($0.height))
                })
        #expect(masks.allSatisfy { $0.fill == model.redactionFill })
        #expect(model.notice == .textLinesCovered(3))
        #expect(model.selection == Set(masks.map { .mask($0.id) }), "the line masks are selected for review")
        #expect(model.session.undoCount == undoCount + 1 && !model.session.isGrouping)
        model.undo()
        #expect(model.document.masks.isEmpty, "one Undo removes the cover and every line mask")
        model.redo()
        #expect(model.document.masks.map(\.sourceRegions) == Self.lines.map { [asset: [$0]] })
        // Ordinary masks: one can be deleted on its own.
        model.select(.mask(try #require(model.document.masks.first).id))
        model.deleteSelection()
        #expect(model.document.masks.count == 2)
    }

    @Test("Recognition is told every source pixel of the image that an existing secure mask fills, never the cover's")
    func existingMasksHidden() async throws {
        // Image A fills the left 400 × 300; image B, 100 × 100, sits beside it.
        let a = ImageAssetInfo(id: AssetID(), pixelSize: PixelSize(width: 400, height: 300), origin: .imported)
        let b = ImageAssetInfo(id: AssetID(), pixelSize: PixelSize(width: 100, height: 100), origin: .imported)
        let onA = Rect<DocumentSpace>(x: 30, y: 60, width: 100, height: 20)
        let masks = [
            // A line already redacted inside the new rectangle.
            SecureMask(
                outputRect: onA, sourceRegions: [a.id: [PixelRect(x: 30, y: 60, width: 100, height: 20)]], fill: .black),
            // Bound to B only and lying over B: it hides none of A's pixels.
            SecureMask(
                outputRect: Rect(x: 420, y: 20, width: 50, height: 50),
                sourceRegions: [b.id: [PixelRect(x: 20, y: 20, width: 50, height: 50)]], fill: .black),
            // Drawn over B, which then moved away: the renderer fills the A pixels now under it too.
            SecureMask(
                outputRect: Rect(x: 300, y: 200, width: 30, height: 30),
                sourceRegions: [b.id: [PixelRect(x: 0, y: 0, width: 30, height: 30)]], fill: .black),
        ]
        let document = Document(
            assets: [a.id: a, b.id: b], canvasSize: Size(width: 500, height: 300),
            layers: [
                ImageLayer(assetID: a.id),
                ImageLayer(assetID: b.id, placement: LayerPlacement(translation: Point(x: 400, y: 0))),
            ], masks: masks)
        let h = EditorHarness(session: DocumentSession(document: document))
        h.sensitiveText.lines = []
        h.sensitiveText.pending = Pending<Void>()
        h.model.setRedactsTextOnly(true)
        await Self.draw(h)
        #expect(h.sensitiveText.lineRequests == [PixelRect(x: 20, y: 20, width: 200, height: 100)])
        #expect(
            h.sensitiveText.hiddenRequests
                == [
                    [PixelRect(x: 30, y: 60, width: 100, height: 20), PixelRect(x: 300, y: 200, width: 30, height: 30)]
                ])
        await Self.finish(h)
        #expect(h.model.document.masks.count == 4 && h.model.notice == .textRedactionKeptArea)
    }

    @Test("No line found keeps the whole rectangle covered, as one undo step")
    func zeroLinesKeepCover() async throws {
        let h = Self.pending(lines: [])
        let undoCount = h.model.session.undoCount
        await Self.draw(h)
        await Self.finish(h)
        #expect(try Self.isCover(h))
        #expect(h.model.notice == .textRedactionKeptArea)
        #expect(h.model.session.undoCount == undoCount + 1 && !h.model.session.isGrouping)
    }

    enum Failure: String, CaseIterable { case error, cancellation, deadline, overdue }

    @Test(
        "A recognizer error, cancellation, the deadline or an overdue answer keeps the cover",
        arguments: Failure.allCases)
    func failureKeepsCover(_ failure: Failure) async throws {
        let h = Self.pending()
        defer { h.model.close() }
        await Self.draw(h)
        let seconds = Double(EditorModel.textRedactionDeadline.components.seconds)
        switch failure {
        case .error:
            h.sensitiveText.error = TestError()
            await Self.finish(h)
        case .cancellation:
            h.sensitiveText.error = CancellationError()
            await Self.finish(h)
        case .deadline:
            await waitFor("deadline armed") { h.clock.pendingSleepCount == 1 }
            #expect(h.clock.sleepRequests.last == EditorModel.textRedactionDeadline)
            h.clock.advance(bySeconds: seconds)
            await waitFor("recognition settled") { !h.model.isMaskingPending }
        case .overdue:
            // The lines arrive after the deadline, before the timer's continuation runs.
            await waitFor("deadline armed") { h.clock.pendingSleepCount == 1 }
            h.clock.stall(bySeconds: seconds + 1)
            await Self.finish(h)
        }
        #expect(try Self.isCover(h))
        #expect(h.model.notice == .textRedactionKeptArea)
        #expect(!h.model.session.isGrouping)
        if failure == .deadline {
            // Lines that arrive after the deadline are ignored.
            h.sensitiveText.pending?.resolve(())
            await drain()
            #expect(try Self.isCover(h) && h.sensitiveText.observedCancellation)
        }
    }

    enum Change: String, CaseIterable { case revision, privacyEpoch }

    @Test("Lines for an earlier document state are discarded and the cover stays", arguments: Change.allCases)
    func staleLinesDiscarded(_ change: Change) async throws {
        let h = Self.pending()
        let model = h.model
        await Self.draw(h)
        let before = model.session.requestIdentity()
        // No person's edit is admitted while pending; this is the document moving on anyway.
        switch change {
        case .revision:
            // Built outside the edit, whose closure runs twice and must build one document.
            let shape = Annotation(
                kind: .rectangle(Rect(x: 300, y: 200, width: 20, height: 20)), style: EditorStyle().annotationStyle)
            #expect(model.performEdit("Shape") { $0.annotations.append(shape) })
            #expect(model.session.privacyEpoch == before.privacyEpoch)
        case .privacyEpoch:
            let rect = Rect<DocumentSpace>(x: 300, y: 200, width: 20, height: 20)
            let id = MaskID()
            #expect(
                model.performEdit("Mask") {
                    $0.masks.append(
                        SecureMask(
                            id: id, outputRect: rect, sourceRegions: try $0.sourceRegions(for: rect), fill: .black))
                })
            #expect(model.session.privacyEpoch != before.privacyEpoch)
        }
        let dropped = model.droppedResultCount
        await Self.finish(h)
        let cover = try #require(model.document.masks.first)
        #expect(cover.outputRect == Self.drawn && model.document.masks.count == (change == .revision ? 1 : 2))
        #expect(model.notice == .textRedactionKeptArea)
        #expect(model.droppedResultCount == dropped + 1)
    }

    @Test("While lines are pending, copy, save, drag, print, pin, Output Preview, edits and Undo are refused")
    func exportsRefusedWhilePending() async throws {
        let h = Self.pending()
        let model = h.model
        await h.settle()
        let undoCount = model.session.undoCount
        await Self.draw(h)
        #expect(!model.canStartExport)
        let requests: [EditorExportRequest] = [
            .copy, .drag, .print, .saveToPreferredFolder,
            .save(URL(fileURLWithPath: "/tmp/recortia-tests/text-redaction.png"), format: .fixed(.png), replacing: nil),
        ]
        for request in requests {
            model.dismissNotice()
            #expect(await model.export(request) == .failed(.maskingUnfinished), "\(request)")
            #expect(model.notice == .textRedactionInProgress)
        }
        model.dismissNotice()
        await model.pin()
        #expect(model.notice == .textRedactionInProgress && h.pins.pins.isEmpty)
        model.setShowsOutputPreview(true)
        #expect(!model.showsOutputPreview)
        model.undo()
        model.deleteSelection()
        model.selectTool(.rectangle)
        h.drag((250, 150), (300, 200))
        #expect(try Self.isCover(h) && model.document.annotations.isEmpty)
        #expect(h.exporter.snapshotCount == 0 && h.clipboard.writes.isEmpty && h.files.saves.isEmpty)
        #expect(h.drag.deliveries.isEmpty && h.printer.presented.isEmpty)

        await Self.finish(h)
        #expect(model.session.undoCount == undoCount + 1)
        #expect(model.canStartExport, "exports are admitted once the lines landed")
    }

    @Test("A line outside the rectangle cannot be bound inside it: the cover stays")
    func lineOutsideCoverKeepsCover() async throws {
        let h = Self.pending(lines: [Self.lines[0], PixelRect(x: 200, y: 100, width: 60, height: 22)])
        await Self.draw(h)
        await Self.finish(h)
        #expect(try Self.isCover(h))
        #expect(h.model.notice == .textRedactionKeptArea)
    }

    @Test("Closing while pending cancels recognition and keeps the cover")
    func closeWhilePending() async throws {
        let h = Self.pending()
        await Self.draw(h)
        h.model.close()
        #expect(!h.model.isMaskingPending && !h.model.session.isGrouping)
        h.sensitiveText.pending?.resolve(())
        await drain()
        #expect(try Self.isCover(h) && h.sensitiveText.observedCancellation)
    }
}

/// RED: the line masks are ordinary secure masks, so exported bytes carry no source pixel of any
/// line, and two documents that differ only in those pixels export identical bytes.
@Suite("Text-only redaction: exported bytes (A-6, RED-01)")
@MainActor
struct TextRedactionExportTests {
    static let secrets = [
        FixtureRect(x: 40, y: 40, width: 140, height: 18), FixtureRect(x: 40, y: 80, width: 100, height: 18),
    ]

    /// The secrets as recognized lines, padded the way the sweep pads them.
    static let lines = secrets.map { PixelRect(x: $0.x - 3, y: $0.y - 3, width: $0.width + 6, height: $0.height + 6) }

    static func masked(green: UInt8) async throws -> SecretExport {
        let fixture = try await SecretExport(secrets: secrets, green: green)
        let h = fixture.harness
        h.sensitiveText.lines = lines
        h.model.setRedactsTextOnly(true)
        h.model.selectTool(.redact)
        h.drag((30, 30), (260, 120))
        await waitFor("lines landed") { !h.model.isMaskingPending }
        #expect(h.model.document.masks.count == 2)
        return fixture
    }

    @Test("No secret pixel under any line mask reaches the exported bytes; the rest of the rectangle does")
    func exportedBytesHideEveryLine() async throws {
        let fixture = try await Self.masked(green: 0)
        let pixels = try await fixture.exported()
        for secret in Self.secrets {
            #expect(fixture.secretPixels(in: pixels, secret) == 0)
            #expect(fixture.uncoveredPixels(in: pixels, secret) == 0)
        }
        // Text only: the white between and beside the lines is still exported.
        #expect(fixture.uncoveredPixels(in: pixels, FixtureRect(x: 190, y: 40, width: 60, height: 60)) > 0)
        fixture.harness.model.undo()
        let undone = try await fixture.exported()
        #expect(fixture.secretPixels(in: undone) > 0, "positive control: after Undo the lines are exported")
    }

    @Test("Documents that differ only in the lines' pixels export identical bytes")
    func exportDoesNotDependOnLinePixels() async throws {
        let red = try await Self.masked(green: 0)
        let other = try await Self.masked(green: 180)
        let redBytes = try await red.exported()
        let otherBytes = try await other.exported()
        #expect(redBytes == otherBytes)
    }
}

/// Hosted CI has no Vision text recognition and declares `RECORTIA_VISION_UNAVAILABLE=1`.
private let visionAvailable = ConditionTrait.enabled(
    if: ProcessInfo.processInfo.environment["RECORTIA_VISION_UNAVAILABLE"] != "1",
    "Vision text recognition is declared unavailable on this runner")

@Suite("Text-only redaction with the live recognizer (A-6)")
@MainActor
struct LiveTextRedactionTests {
    @Test("Vision finds each typed line, and no painted pixel inside the rectangle is exported", visionAvailable)
    func liveLinesCoverEveryGlyph() async throws {
        let sample = try TextCorpus.render(
            id: "live-lines", language: .english, category: .prose, theme: .light, pointSize: 15, scale: 2,
            lines: ["Quarterly figures are confidential", "Send the draft to legal before Friday"])
        let store = ImageStore()
        let info = await store.insert(
            try ImageDecoder.canonicalize(sample.image),
            origin: .captured(
                EditorFixtures.captureGeometry(width: sample.image.width, height: sample.image.height, scale: 2)))
        let h = EditorHarness()
        h.assets.store = store
        h.exporter.pipeline = ExportPipeline(renderer: PrivacyRenderer(store: store))
        let environment = EditorEnvironment(
            renderer: h.renderer, export: h.export, folders: h.folders, textRecognition: h.recognizer,
            qrDecoder: h.qr, sensitiveText: LiveSensitiveText(store: store), assets: h.assets, input: h.input,
            pins: h.pins, textClipboard: h.textClipboard, links: h.links, settings: h.settings, clock: h.clock)
        let model = EditorModel(session: DocumentSession(document: Document(asset: info)), environment: environment)
        defer { model.close() }
        model.setRedactsTextOnly(true)
        model.selectTool(.redact)
        let area = PixelRect(x: 10, y: 10, width: sample.image.width - 20, height: sample.image.height - 20)
        model.pointerDown(at: Point(x: Double(area.x), y: Double(area.y)))
        model.pointerDragged(to: Point(x: Double(area.maxX), y: Double(area.maxY)))
        model.pointerUp(at: Point(x: Double(area.maxX), y: Double(area.maxY)))
        #expect(model.isMaskingPending)
        // The deadline runs on the harness's manual clock, so only Vision decides here.
        let clock = ContinuousClock()
        let start = clock.now
        while model.isMaskingPending, clock.now - start < .seconds(60) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.document.masks.count == 2, "\(model.document.masks.map(\.outputRect))")

        await model.settlePreviews()
        #expect(await model.export(.copy) == .copied)
        let exported = try ContainerInspector.decodePixels(try #require(h.clipboard.writes.last).bytes)
        let source = try ContainerInspector.pixels(of: sample.image)
        let background = source.pixel(x: 0, y: 0)
        var painted = 0, shown = 0
        for y in area.y..<area.maxY {
            for x in area.x..<area.maxX where source.pixel(x: x, y: y) != background {
                painted += 1
                if exported.pixel(x: x, y: y) == source.pixel(x: x, y: y) { shown += 1 }
            }
        }
        #expect(painted > 0 && shown == 0, "\(shown) of \(painted) painted pixels exported")
        model.undo()
        await model.settlePreviews()
        #expect(await model.export(.copy) == .copied)
        let undone = try ContainerInspector.decodePixels(try #require(h.clipboard.writes.last).bytes)
        #expect(undone != exported, "positive control: after Undo the text is exported")
    }
}
