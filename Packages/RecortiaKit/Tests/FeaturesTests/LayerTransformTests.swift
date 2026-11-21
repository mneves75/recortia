import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Features

/// Rotate, flip, duplicate and crop presets (A-10). Geometry is checked on the model; privacy and
/// alignment on exported pixels through the real export pipeline.
@Suite("Rotate, flip, duplicate and crop presets (A-10)")
@MainActor
struct LayerTransformTests {
    private static let secret = FixtureRect(x: 20, y: 10, width: 12, height: 8)

    /// A 100 × 75 image layer at (150, 100) on a 400 × 300 canvas, selected.
    private func layered() async throws -> (SecretExport, LayerID) {
        let fixture = try await SecretExport(secrets: [])
        let id = try await fixture.addLayer(width: 100, height: 75, secrets: [Self.secret])
        let m = fixture.harness.model
        m.setFrame(Rect(x: 150, y: 100, width: 100, height: 75), for: .layer(id))
        m.setSelection([.layer(id)])
        return (fixture, id)
    }

    private func layer(_ id: LayerID, in m: EditorModel) throws -> ImageLayer {
        try #require(m.document.layers.first { $0.id == id })
    }

    @Test("A layer turn keeps its top-left corner and swaps its sides; source pixels land where the turn sends them")
    func layerTurnGeometry() async throws {
        let (fixture, id) = try await layered()
        let m = fixture.harness.model
        let size = PixelSize(width: 100, height: 75)
        m.transformSelectedLayers(.rotateRight)
        var turned = try layer(id, in: m)
        #expect(turned.documentBounds(assetSize: size) == Rect(x: 150, y: 100, width: 75, height: 100))
        // The source's top-left pixel corner is now the top-right corner: a clockwise turn.
        #expect(turned.sourceToDocument(assetSize: size).apply(Point(x: 0, y: 0)) == Point(x: 225, y: 100))
        m.undo()
        m.transformSelectedLayers(.flipHorizontal)
        turned = try layer(id, in: m)
        #expect(turned.documentBounds(assetSize: size) == Rect(x: 150, y: 100, width: 100, height: 75))
        #expect(turned.sourceToDocument(assetSize: size).apply(Point(x: 0, y: 0)) == Point(x: 250, y: 100))
        m.undo()
        m.transformSelectedLayers(.flipVertical)
        turned = try layer(id, in: m)
        #expect(turned.sourceToDocument(assetSize: size).apply(Point(x: 0, y: 0)) == Point(x: 150, y: 175))
    }

    @Test("Four turns and two mirrors give back the same placement, for a layer and for the whole image")
    func turnsAndMirrorsReturnToIdentity() async throws {
        let (fixture, id) = try await layered()
        let m = fixture.harness.model
        m.setFillColor(.yellow)
        m.selectTool(.rectangle)
        fixture.harness.drag((40, 30), (90, 60))
        m.selectTool(.arrow)
        fixture.harness.drag((300, 40), (360, 90))
        m.selectTool(.select)
        let original = m.document
        for transform in ImageTransform.allCases {
            let repeats = transform.swapsSides ? 4 : 2
            m.setSelection([.layer(id)])
            for _ in 0..<repeats { m.transformSelectedLayers(transform) }
            #expect(m.document == original, "\(repeats) × layer \(transform)")
            for _ in 0..<repeats { m.transformImage(transform) }
            #expect(m.document == original, "\(repeats) × image \(transform)")
        }
        m.setSelection([.layer(id)])
        m.transformSelectedLayers(.rotateRight)
        m.transformSelectedLayers(.rotateLeft)
        m.transformImage(.rotateLeft)
        m.transformImage(.rotateRight)
        #expect(m.document == original, "a turn and its opposite")
    }

    @Test("Each turn, mirror and duplicate is one undo step that Undo reverses exactly")
    func oneUndoStepEach() async throws {
        let (fixture, id) = try await layered()
        let m = fixture.harness.model
        let commands: [(String, () -> Void)] =
            ImageTransform.allCases.flatMap { transform in
                [
                    (
                        "layer \(transform)",
                        {
                            m.setSelection([.layer(id)]); m.transformSelectedLayers(transform)
                        }
                    ),
                    ("image \(transform)", { m.transformImage(transform) }),
                ]
            } + [
                (
                    "duplicate",
                    {
                        m.setSelection([.layer(id)]); m.duplicateSelection()
                    }
                )
            ]
        for (name, run) in commands {
            let before = m.document
            let count = m.session.undoCount
            run()
            #expect(m.document != before, "\(name) changes the document")
            #expect(m.session.undoCount == count + 1, "\(name) is one undo step")
            m.undo()
            #expect(m.document == before, "Undo reverses \(name)")
        }
    }

    @Test("A turned image layer keeps its corner resize handles and resizes uniformly")
    func turnedLayerKeepsHandles() async throws {
        let (fixture, id) = try await layered()
        let m = fixture.harness.model
        m.transformSelectedLayers(.rotateLeft)
        #expect(m.selectionHandles.count == 4)
        m.setFrame(Rect(x: 150, y: 100, width: 150, height: 200), for: .layer(id))
        #expect(try layer(id, in: m).placement.scale == 2)
    }

    @Test("A mirrored layer's translation is still its top-left corner, so Side by Side places it in the row")
    func mirroredLayerKeepsTranslationMeaning() async throws {
        let (fixture, id) = try await layered()
        let m = fixture.harness.model
        m.transformSelectedLayers(.flipHorizontal)
        m.arrangeSideBySide(spacing: 0)
        let first = try #require(m.document.layers.first)
        let size = try #require(m.document.assets[first.assetID]?.pixelSize)
        let width = first.documentBounds(assetSize: size).width
        #expect(m.frame(of: .layer(id)) == Rect(x: width, y: 0, width: 400, height: 300))
        #expect(try layer(id, in: m).placement.mirrored, "the row keeps the mirror")
    }

    @Test("Turns and mirrors are refused during text input and in Output Preview")
    func refusedWhileTextOrPreview() async throws {
        let (fixture, _) = try await layered()
        let m = fixture.harness.model
        let before = m.document
        m.setShowsOutputPreview(true)
        #expect(!m.canTransformImage && !m.canTransformLayers)
        m.transformImage(.rotateRight)
        m.transformSelectedLayers(.rotateRight)
        #expect(m.document == before)
        m.setShowsOutputPreview(false)
        m.selectTool(.text)
        fixture.harness.click(20, 20)
        #expect(!m.canTransformImage)
        m.transformImage(.flipVertical)
        #expect(m.document == before)
    }

    // MARK: Masks (decisions 2026-11-20, "Secure masks after a layer moves")

    @Test("Before a layer turns, a box binds the layer pixels under it, keeps its place, and hides them after")
    func layerTurnBindsFirst() async throws {
        let fixture = try await SecretExport(secrets: [])
        let m = fixture.harness.model
        // The box comes first, so the layer added under it is protected only by the box.
        m.selectTool(.redact)
        fixture.harness.drag((170, 110), (182, 118))
        let mask = try #require(m.document.masks.first)
        let id = try await fixture.addLayer(width: 100, height: 75, secrets: [Self.secret])
        m.setFrame(Rect(x: 150, y: 100, width: 100, height: 75), for: .layer(id))
        let asset = try #require(m.document.layers.last?.assetID)
        #expect(mask.sourceRegions[asset] == nil, "positive control: the late layer is not bound yet")
        #expect(fixture.secretPixels(in: try await fixture.exported()) == 0)
        for transform in ImageTransform.allCases {
            m.setSelection([.layer(id)])
            m.transformSelectedLayers(transform)
            let after = try #require(m.document.masks.first)
            #expect(after.outputRect == mask.outputRect, "\(transform): the box stays where it was drawn")
            #expect(
                after.sourceRegions[asset] == [PixelRect(x: 20, y: 10, width: 12, height: 8)],
                "\(transform): the pixels under the box are bound before the layer moves")
            #expect(fixture.secretPixels(in: try await fixture.exported()) == 0, "\(transform)")
            m.undo()
        }
    }

    @Test("A duplicated layer carries the original's bindings, even moved away from every box")
    func duplicateCarriesBindings() async throws {
        for masked in [true, false] {
            let (fixture, id) = try await layered()
            let m = fixture.harness.model
            if masked {
                m.selectTool(.redact)
                fixture.harness.drag((170, 110), (182, 118))
                m.selectTool(.select)
            }
            m.setSelection([.layer(id)])
            m.duplicateSelection()
            let copy = try #require(m.document.layers.last)
            let original = try layer(id, in: m)
            #expect(copy.id != id && copy.assetID == original.assetID)
            #expect(copy.placement.translation == Point(x: 160, y: 110), "offset by 10 pt")
            m.setFrame(Rect(x: 10, y: 200, width: 100, height: 75), for: .layer(copy.id))
            m.setSelection([.layer(copy.id)])
            m.transformSelectedLayers(.rotateRight)
            let box = m.document.masks.first?.outputRect
            let frame = try #require(m.frame(of: .layer(copy.id)))
            #expect(box.map { !$0.intersects(frame) } ?? true, "the copy is clear of every box")
            let pixels = try await fixture.exported()
            // The copy's secret: source (20, 10, 12 × 8) turned clockwise at (10, 200).
            let copied = FixtureRect(x: 10 + 75 - 18, y: 220, width: 8, height: 12)
            if masked {
                #expect(fixture.secretPixels(in: pixels) == 0, "no protected pixel in either layer")
            } else {
                #expect(fixture.secretPixels(in: pixels, copied) == 96, "positive control: the copy shows it unmasked")
            }
        }
    }

    // MARK: Whole-image alignment

    @Test("A whole-image turn or mirror exports the original export turned or mirrored, pixel for pixel")
    func imageTransformKeepsExportAligned() async throws {
        let secrets = [
            FixtureRect(x: 20, y: 30, width: 40, height: 20), FixtureRect(x: 300, y: 200, width: 30, height: 60),
        ]
        let fixture = try await SecretExport(width: 400, height: 300, secrets: secrets)
        let m = fixture.harness.model
        m.selectTool(.redact)
        fixture.harness.drag((300, 200), (330, 260))
        m.clearSelection()
        m.setStrokeColor(RGBA(r: 0, g: 90, b: 200))
        m.setFillColor(.yellow)
        m.selectTool(.rectangle)
        fixture.harness.drag((100, 120), (180, 160))
        m.selectTool(.select)
        let before = try await fixture.exported()
        #expect(fixture.secretPixels(in: before) == 800, "positive control: the unmasked patch is exported")
        for transform in ImageTransform.allCases {
            m.transformImage(transform)
            let after = try await fixture.exported()
            let (w, h) = (before.width, before.height)
            #expect(
                transform.swapsSides ? (after.width, after.height) == (h, w) : (after.width, after.height) == (w, h))
            var mismatched = 0
            for y in 0..<after.height {
                for x in 0..<after.width {
                    let (sx, sy): (Int, Int) =
                        switch transform {
                        case .rotateRight: (y, h - 1 - x)
                        case .rotateLeft: (w - 1 - y, x)
                        case .flipHorizontal: (w - 1 - x, y)
                        case .flipVertical: (x, h - 1 - y)
                        }
                    if after.pixel(x: x, y: y) != before.pixel(x: sx, y: sy) { mismatched += 1 }
                }
            }
            #expect(mismatched == 0, "\(transform): \(mismatched) pixels differ from the transformed export")
            #expect(fixture.secretPixels(in: after) == 800, "\(transform): the masked patch stays hidden")
            m.undo()
        }
    }

    // MARK: Crop presets

    @Test("Each crop preset holds its ratio from every corner, on whole pixels inside the canvas")
    func cropPresetsHoldTheirRatio() async throws {
        let fixture = try await SecretExport(width: 400, height: 300, secrets: [])
        let m = fixture.harness.model
        m.selectTool(.crop)
        let anchor = (200.3, 150.4)
        let pointers = [(330.0, 190.0), (60.0, 20.0), (390.0, 10.0), (15.0, 290.0), (205.0, 296.0), (12.0, 151.0)]
        for aspect in CropAspect.allCases where aspect != .free {
            m.setCropAspect(aspect)
            let ratio = try #require(aspect.ratio(canvas: m.document.canvasSize))
            for pointer in pointers {
                m.setCrop(nil)
                m.pointerDown(at: Point(x: anchor.0, y: anchor.1))
                m.pointerDragged(to: Point(x: pointer.0, y: pointer.1))
                guard case .region(.crop, let draft)? = m.draft else {
                    Issue.record("\(aspect) \(pointer): no crop draft")
                    continue
                }
                m.pointerUp(at: Point(x: pointer.0, y: pointer.1))
                let crop = try #require(m.document.crop, "\(aspect) \(pointer)")
                #expect(crop == draft, "\(aspect) \(pointer): the crop is the rectangle shown while drawing")
                #expect(
                    abs(crop.height - crop.width * ratio.height / ratio.width) <= 0.5,
                    "\(aspect) \(pointer): \(crop.width) × \(crop.height)")
                #expect(crop.minX == crop.minX.rounded() && crop.width == crop.width.rounded())
                #expect(crop.intersection(m.document.canvasRect) == crop, "\(aspect) \(pointer): inside the canvas")
                let corners = [crop.minX, crop.maxX].flatMap { x in [crop.minY, crop.maxY].map { (x, $0) } }
                #expect(corners.contains { $0 == (200, 150) }, "\(aspect) \(pointer): drawn from the anchor")
            }
        }
        m.setCropAspect(.original)
        m.setCrop(nil)
        m.transformImage(.rotateRight)
        m.selectTool(.crop)
        fixture.harness.drag((0, 0), (150, 100))
        #expect(m.document.crop == Rect(x: 0, y: 0, width: 150, height: 200), "Original follows the turned canvas")
    }

    @Test("Free cropping is unchanged: the dragged rectangle, or a square with Shift")
    func freeCropUnchanged() async throws {
        let fixture = try await SecretExport(width: 400, height: 300, secrets: [])
        let m = fixture.harness.model
        m.selectTool(.crop)
        fixture.harness.drag((10, 20), (110, 70))
        #expect(m.document.crop == Rect(x: 10, y: 20, width: 100, height: 50))
        fixture.harness.drag((10, 20), (110, 70), modifiers: .shift)
        #expect(m.document.crop == Rect(x: 10, y: 20, width: 100, height: 100))
    }
}
