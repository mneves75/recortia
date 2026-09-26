import Domain
import Foundation
import Imaging
import Testing

@testable import Features

// Failure modes (FR-12, FR-13, COMP-01): an added or resized image stretched out of its aspect
// ratio; a pasted image read without an explicit paste; import failures swallowed; side-by-side
// layers overlapping or clipped by the canvas; canvas growth that leaves content behind or
// detaches masks from their pixels; a duplicate image layer escaping its asset's masks;
// presentation values outside safe ranges; a magnifier whose source is not a document rect.
@Suite("Editor composition and presentation (COMP-01)")
@MainActor
struct EditorCompositionTests {
    private let fileURL = URL(fileURLWithPath: "/tmp/framepin-tests/never-read.png")

    private func aspect(_ document: Document, _ layer: ImageLayer) -> Double? {
        guard let asset = document.assets[layer.assetID] else { return nil }
        let bounds = layer.documentBounds(assetSize: asset.pixelSize)
        return bounds.width / bounds.height
    }

    @Test("An added image keeps its aspect ratio and is scaled down to fit the canvas")
    func addImageLayerFits() async throws {
        let h = EditorHarness(session: EditorFixtures.session(width: 10, height: 10))
        h.input.files[fileURL] = .success(Data([1, 2, 3]))
        #expect(await h.model.addImageLayer(from: .file(fileURL)))
        let document = h.model.document
        #expect(document.layers.count == 2)
        let added = try #require(document.layers.last)
        #expect(added.placement.scale == 0.625)
        #expect(aspect(document, added) == 16.0 / 9)
        let bounds = try #require(h.model.frame(of: .layer(added.id)))
        #expect(document.canvasRect.union(bounds) == document.canvasRect)
        #expect(h.model.selection == [.layer(added.id)])
        #expect(h.input.pasteboardReads == 0)
        #expect(h.model.session.undoCount == 1)
    }

    @Test("Paste reads the clipboard only when asked, and failures are reported")
    func pasteAndFailures() async {
        let h = EditorHarness()
        #expect(await h.model.addImageLayer(from: .pasteboard) == false)
        #expect(h.model.notice == .importFailed(.nothingToPaste))
        #expect(h.input.pasteboardReads == 1)
        h.input.files[fileURL] = .failure(.tooManyPixels)
        #expect(await h.model.addImageLayer(from: .file(fileURL)) == false)
        #expect(h.model.notice == .importFailed(.tooManyPixels))
        #expect(h.model.document.layers.count == 1)
    }

    @Test("Side by side scales every image uniformly to one height with no overlap")
    func sideBySide() async throws {
        let h = EditorHarness()
        h.input.files[fileURL] = .success(Data([1]))
        #expect(await h.model.addImageLayer(from: .file(fileURL)))
        h.model.arrangeSideBySide()
        let document = h.model.document
        let frames = document.layers.compactMap { h.model.frame(of: .layer($0.id)) }
        #expect(frames.count == 2)
        #expect(frames.allSatisfy { $0.minY == 0 && abs($0.height - 300) < 1e-9 })
        #expect(frames[1].minX == frames[0].maxX + EditorModel.sideBySideSpacing)
        #expect(abs(aspect(document, document.layers[0])! - 400.0 / 300) < 1e-12)
        #expect(abs(aspect(document, document.layers[1])! - 16.0 / 9) < 1e-12)
        #expect(document.canvasSize == Size(width: (frames[1].maxX).rounded(.up), height: 300))
        h.model.undo()
        #expect(h.model.document.canvasSize == Size(width: 400, height: 300))
    }

    @Test("Resizing an image from a corner handle keeps its aspect ratio")
    func layerResizeKeepsAspect() throws {
        let h = EditorHarness()
        let layer = try #require(h.model.document.layers.first)
        h.model.select(.layer(layer.id))
        h.drag((400, 300), (600, 320))
        let resized = try #require(h.model.document.layers.first)
        #expect(resized.placement.scale == 1.5)
        #expect(aspect(h.model.document, resized) == 400.0 / 300)
        h.model.setFrame(Rect(x: 10, y: 20, width: 200, height: 999), for: .layer(layer.id))
        #expect(h.model.frame(of: .layer(layer.id)) == Rect(x: 10, y: 20, width: 200, height: 150))
    }

    @Test("Fitting the canvas grows it and shifts every object together with its masks")
    func fitCanvasShiftsEverything() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.redact)
        h.drag((10, 10), (30, 30))
        let assetID = try #require(m.document.layers.first?.assetID)
        let regions = m.document.masks.first?.sourceRegions
        m.selectTool(.arrow)
        h.drag((50, 50), (150, 50))
        let layer = try #require(m.document.layers.first)
        m.setFrame(Rect(x: -50, y: -20, width: 400, height: 300), for: .layer(layer.id))
        m.fitCanvasToContent()
        let document = m.document
        #expect(document.canvasSize == Size(width: 450, height: 320))
        #expect(document.layers.first?.placement.translation == .zero)
        #expect(document.annotations.first?.kind == .arrow(start: Point(x: 100, y: 70), end: Point(x: 200, y: 70)))
        #expect(document.masks.first?.outputRect == Rect(x: 60, y: 30, width: 20, height: 20))
        #expect(document.masks.first?.sourceRegions == regions)
        #expect(document.masks.first?.sourceRegions[assetID] != nil)
    }

    @Test("Expanding the canvas adds margins and moves content by the top/left margins")
    func expandCanvas() {
        let h = EditorHarness()
        h.model.selectTool(.rectangle)
        h.drag((10, 10), (20, 20))
        h.model.expandCanvas(top: 5, left: 15, bottom: 0, right: 30)
        #expect(h.model.document.canvasSize == Size(width: 445, height: 305))
        #expect(h.model.document.annotations.first?.kind == .rectangle(Rect(x: 25, y: 15, width: 10, height: 10)))
        h.model.expandCanvas(top: -1)
        #expect(h.model.session.undoCount == 2)
    }

    @Test("A duplicated image layer references the same asset, so its masks apply to both")
    func duplicateLayerSharesMasks() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.redact)
        h.drag((10, 10), (30, 30))
        let layer = try #require(m.document.layers.first)
        m.select(.layer(layer.id))
        m.duplicateSelection()
        #expect(m.document.layers.count == 2)
        #expect(Set(m.document.layers.map(\.assetID)).count == 1)
        #expect(m.document.maskedRegions(for: layer.assetID) == [PixelRect(x: 10, y: 10, width: 20, height: 20)])
    }

    @Test("Transparency comparison toggles the top image between 50 % and opaque")
    func transparencyComparison() async throws {
        let h = EditorHarness()
        h.model.toggleTransparencyComparison()
        #expect(!h.model.canUndo)
        h.input.files[fileURL] = .success(Data([1]))
        #expect(await h.model.addImageLayer(from: .file(fileURL)))
        h.model.toggleTransparencyComparison()
        #expect(h.model.isComparingTransparency)
        #expect(h.model.document.layers.last?.opacity == 0.5)
        h.model.toggleTransparencyComparison()
        #expect(!h.model.isComparingTransparency)
        h.model.setLayerOpacity(7, for: try #require(h.model.document.layers.last?.id))
        #expect(h.model.document.layers.last?.opacity == 1)
    }

    @Test("Align moves one object to the canvas edge, several to their shared bounds")
    func align() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.rectangle)
        h.drag((50, 50), (100, 100))
        let first = try #require(m.selection.first)
        m.align(.right)
        #expect(m.frame(of: first)?.maxX == 400)
        h.drag((20, 150), (60, 200))
        let second = try #require(m.selection.first)
        m.select(first, extending: true)
        m.align(.top)
        #expect(m.frame(of: first)?.minY == 50)
        #expect(m.frame(of: second)?.minY == 50)
    }

    @Test("Presentation values are clamped and each change is one undo step")
    func presentation() {
        let h = EditorHarness()
        let m = h.model
        m.setBackground(.linearGradient(from: .red, to: .yellow, angleDegrees: 45))
        m.setPadding(-5)
        m.setPadding(48)
        m.setCornerRadius(10_000)
        m.setShadow(Presentation.Shadow())
        m.setPadding(.nan)
        let presentation = m.document.presentation
        #expect(presentation.background == .linearGradient(from: .red, to: .yellow, angleDegrees: 45))
        #expect(presentation.padding == 48)
        #expect(presentation.cornerRadius == 512)
        #expect(presentation.shadow == Presentation.Shadow())
        #expect(m.session.undoCount == 4)
        for _ in 0..<4 { m.undo() }
        #expect(m.document.presentation == .plain)
    }

    @Test("Spotlight and magnifier callouts use document rectangles; the magnifier enlarges 2×")
    func callouts() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.spotlight)
        h.drag((10, 10), (60, 40))
        m.selectTool(.magnifier)
        h.drag((100, 100), (130, 120))
        #expect(m.document.callouts.count == 2)
        guard case .spotlight(let spot, let dim) = m.document.callouts[0].kind,
            case .magnifier(let source, let destination) = m.document.callouts[1].kind
        else {
            Issue.record("unexpected callout kinds")
            return
        }
        #expect(spot == Rect(x: 10, y: 10, width: 50, height: 30))
        #expect(dim == EditorModel.defaultSpotlightDim)
        #expect(source == Rect(x: 100, y: 100, width: 30, height: 20))
        #expect(destination.width == 60 && destination.height == 40)
        #expect(m.document.canvasRect.union(destination) == m.document.canvasRect)
        #expect(!destination.intersects(source))
        let id = m.document.callouts[1].id
        m.setMagnifierSource(Rect(x: 0, y: 0, width: 10, height: 10), for: id)
        guard case .magnifier(let moved, _) = m.document.callouts[1].kind else { return }
        #expect(moved == Rect(x: 0, y: 0, width: 10, height: 10))
    }

    @Test("Crop and resize are reversible and snapped to whole pixels")
    func cropAndResize() {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.crop)
        h.drag((10.4, 20.6), (200.2, 150.7))
        #expect(m.document.crop == Rect(x: 10, y: 21, width: 190, height: 130))
        m.setResizeScale(99)
        #expect(m.document.resizeScale == EditorModel.resizeRange.upperBound)
        m.setCrop(nil)
        #expect(m.document.crop == nil)
        m.undo()
        m.undo()
        #expect(m.document.crop != nil && m.document.resizeScale == 1)
    }
}
