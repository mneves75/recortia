import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Features

// Acceptance gate for the mask rule (R4): no editor operation other than an explicit mask edit may
// make the export depend on pixels a mask protected. Two documents differ only inside the masked
// patches, on the bottom image (bound when each mask was made) and on a pasted image (one patch
// protected only by the box over it when it was pasted); an image imported mid-run may carry a
// further variant patch placed exactly under a box. The same seeded sequence of non-mask edits,
// through the model's own entry points, must leave their exports identical after every step.
// Setup is outside Undo's reach: undoing a mask's creation is an explicit mask edit.
@Suite("Non-mask edits never reveal protected pixels (R4)")
@MainActor
struct EditorMaskPropertyTests {
    private static let early = FixtureRect(x: 30, y: 30, width: 10, height: 10)
    private static let late = FixtureRect(x: 150, y: 100, width: 15, height: 10)
    private static let both = FixtureRect(x: 50, y: 10, width: 15, height: 10)

    /// 200 fixed seeds in eight groups that run concurrently.
    @Test(
        "Seeded sequences of up to 12 non-mask edits keep the two variants' exports identical",
        arguments: 0..<8)
    func nonMaskEditsKeepVariantsIdentical(group: Int) async throws {
        var compared = 0
        for seed in group * 25..<(group + 1) * 25 {
            var rng = SplitMix64(seed: UInt64(seed))
            let steps = (0..<Int.random(in: 1...12, using: &rng)).map { _ in Step.random(using: &rng) }
            let variants = [try await Self.variant(green: 0), try await Self.variant(green: 200)]
            for (index, step) in steps.enumerated() {
                for (green, fixture) in zip([UInt8(0), 200], variants) { await step.apply(to: fixture, green: green) }
                let red = await Self.outcome(variants[0])
                let other = await Self.outcome(variants[1])
                guard red == other, case .success = red else {
                    Issue.record(
                        """
                        seed \(seed), step \(index + 1) of [\(steps.map { "\($0)" }.joined(separator: ", "))]: the exports differ or failed \
                        (\(Self.describe(red)) vs \(Self.describe(other)))
                        """)
                    return
                }
                compared += 1
            }
        }
        #expect(compared > 100)
    }

    private enum Outcome: Equatable {
        case success(DecodedPixels)
        case failure(String)
    }

    private static func outcome(_ fixture: SecretExport) async -> Outcome {
        do { return .success(try await fixture.exported()) } catch { return .failure("\(error)") }
    }

    private static func describe(_ outcome: Outcome) -> String {
        switch outcome {
        case .success(let pixels): "\(pixels.width)×\(pixels.height) pixels"
        case .failure(let error): "export failed: \(error)"
        }
    }

    /// The bottom image has all three patches; `early`'s mask predates the pasted image, which
    /// carries `early` and `both`, so its `early` patch is protected only by the box over it.
    private static func variant(green: UInt8) async throws -> SecretExport {
        let fixture = try await SecretExport(width: 200, height: 150, secrets: [early, late, both], green: green)
        let h = fixture.harness
        h.model.selectTool(.redact)
        h.drag(corner(early), far(early))
        try await fixture.addLayer(width: 100, height: 75, secrets: [early, both], green: green)
        h.model.selectTool(.redact)
        h.drag(corner(late), far(late))
        h.drag(corner(both), far(both))
        return fixture.withoutHistory()
    }

    private static func corner(_ r: FixtureRect) -> (Double, Double) { (Double(r.x), Double(r.y)) }
    private static func far(_ r: FixtureRect) -> (Double, Double) { (Double(r.x + r.width), Double(r.y + r.height)) }
}

/// One editor operation that is not an explicit mask edit, with every random choice drawn up front
/// so both variants receive exactly the same input.
private enum Step {
    case nudgeLayer(pick: Int, dx: Double, dy: Double)
    case setLayerFrame(pick: Int, x: Double, y: Double, factor: Double)
    case layerScale(pick: Int, scale: Double)
    case resizeLayer(pick: Int, handle: Int, dx: Double, dy: Double)
    case sideBySide
    case align(picks: Int, alignment: EditorAlignment)
    case dragLayer(x: Double, y: Double, dx: Double, dy: Double)
    case importImage(width: Int, height: Int, underMask: Int?)
    case duplicate(pick: Int)
    case delete(pick: Int)
    case reorder(pick: Int, order: EditorZOrder)
    case layerOpacity(pick: Int, opacity: Double)
    case addRectangle(x: Double, y: Double, width: Double, height: Double)
    case addText(x: Double, y: Double, text: String)
    case restyle(pick: Int, lineWidth: Double, fontSize: Double)
    case continuousRestyle(pick: Int, widths: [Double])
    case nudgeAnnotation(pick: Int, dx: Double, dy: Double)
    case addMagnifier(x: Double, y: Double, width: Double, height: Double)
    case nudgeCallout(pick: Int, dx: Double, dy: Double)
    case fitCanvas
    case crop(x: Double, y: Double, width: Double, height: Double)
    case resetCrop
    case undo
    case redo
    case togglePreview
    case zoomPan(zoom: Double, dx: Double, dy: Double)
    // Mixed mask and layer edits (R5-01): a layer always moves, so these are not explicit mask
    // edits; an align that would move only masks is undone (that would be an explicit edit).
    case alignMixed(picks: Int, alignment: EditorAlignment)
    case nudgeMixed(pick: Int, dx: Double)
    case zoomedDragMixed(pick: Int, viewDX: Double)

    static func random(using rng: inout SplitMix64) -> Step {
        func coordinate() -> Double { Double(Int.random(in: -25...200, using: &rng)) }
        func delta() -> Double { Double(Int.random(in: -60...60, using: &rng)) }
        func length() -> Double { Double(Int.random(in: 5...75, using: &rng)) }
        let pick = Int.random(in: 0..<64, using: &rng)
        switch Int.random(in: 0..<29, using: &rng) {
        case 0: return .nudgeLayer(pick: pick, dx: delta(), dy: delta())
        case 1:
            return .setLayerFrame(
                pick: pick, x: coordinate(), y: coordinate(), factor: Double.random(in: 0.4...1.6, using: &rng))
        case 2: return .layerScale(pick: pick, scale: Double.random(in: 0.3...2, using: &rng))
        case 3: return .resizeLayer(pick: pick, handle: Int.random(in: 0..<4, using: &rng), dx: delta(), dy: delta())
        case 4: return .sideBySide
        case 5: return .align(picks: pick, alignment: EditorAlignment.allCases.randomElement(using: &rng) ?? .left)
        case 6: return .dragLayer(x: coordinate(), y: coordinate(), dx: delta(), dy: delta())
        case 7:
            return .importImage(
                width: 2 * Int.random(in: 10...100, using: &rng), height: 2 * Int.random(in: 10...75, using: &rng),
                underMask: Bool.random(using: &rng) ? pick : nil)
        case 8: return .duplicate(pick: pick)
        case 9: return .delete(pick: pick)
        case 10: return .reorder(pick: pick, order: [.forward, .backward, .front, .back][pick % 4])
        case 11: return .layerOpacity(pick: pick, opacity: Double.random(in: 0...1, using: &rng))
        case 12: return .addRectangle(x: coordinate(), y: coordinate(), width: length(), height: length())
        case 13: return .addText(x: coordinate(), y: coordinate(), text: String(repeating: "W", count: 1 + pick % 8))
        case 14:
            return .restyle(
                pick: pick, lineWidth: Double(Int.random(in: 1...20, using: &rng)),
                fontSize: Double(Int.random(in: 8...72, using: &rng)))
        case 15:
            return .continuousRestyle(
                pick: pick, widths: (0..<3).map { _ in Double(Int.random(in: 1...20, using: &rng)) })
        case 16: return .nudgeAnnotation(pick: pick, dx: delta(), dy: delta())
        case 17: return .addMagnifier(x: coordinate(), y: coordinate(), width: length(), height: length())
        case 18: return .nudgeCallout(pick: pick, dx: delta(), dy: delta())
        case 19: return .fitCanvas
        case 20: return .crop(x: coordinate(), y: coordinate(), width: length() * 2, height: length() * 2)
        case 21: return .resetCrop
        case 22: return .undo
        case 23: return .redo
        case 24: return .togglePreview
        case 25:
            return .alignMixed(picks: pick, alignment: EditorAlignment.allCases.randomElement(using: &rng) ?? .left)
        case 26: return .nudgeMixed(pick: pick, dx: [0.45, -0.45, 1, 15][Int.random(in: 0..<4, using: &rng)])
        case 27: return .zoomedDragMixed(pick: pick, viewDX: [3.6, -3.6, 8][Int.random(in: 0..<3, using: &rng)])
        default: return .zoomPan(zoom: Double.random(in: 0.1...4, using: &rng), dx: delta(), dy: delta())
        }
    }

    /// `green` is the variant's patch color, used only for a patch placed exactly under a box.
    @MainActor
    func apply(to fixture: SecretExport, green: UInt8) async {
        let h = fixture.harness
        let m = h.model
        let layers = m.document.layers.map { EditorItemID.layer($0.id) }
        let annotations = m.document.annotations.map { EditorItemID.annotation($0.id) }
        let callouts = m.document.callouts.map { EditorItemID.callout($0.id) }
        func one(_ items: [EditorItemID], _ pick: Int) -> EditorItemID? {
            items.isEmpty ? nil : items[pick % items.count]
        }
        m.selectTool(.select)
        switch self {
        case .nudgeLayer(let pick, let dx, let dy):
            guard let layer = one(layers, pick) else { return }
            m.setSelection([layer])
            m.nudgeSelection(dx: dx, dy: dy)
        case .setLayerFrame(let pick, let x, let y, let factor):
            guard let layer = one(layers, pick), let frame = m.frame(of: layer) else { return }
            m.setFrame(Rect(x: x, y: y, width: frame.width * factor, height: frame.height * factor), for: layer)
        case .layerScale(let pick, let scale):
            guard case .layer(let id)? = one(layers, pick) else { return }
            m.setLayerScale(scale, for: id)
        case .resizeLayer(let pick, let handle, let dx, let dy):
            guard let layer = one(layers, pick) else { return }
            m.setSelection([layer])
            let handles = m.selectionHandles
            guard !handles.isEmpty else { return }
            let p = handles[handle % handles.count].point
            h.drag((p.x, p.y), (p.x + dx, p.y + dy))
        case .sideBySide:
            m.arrangeSideBySide()
        case .align(let picks, let alignment):
            let candidates = layers + annotations
            m.setSelection(Set(candidates.enumerated().filter { picks & (1 << ($0.offset % 6)) != 0 }.map(\.element)))
            m.align(alignment)
        case .dragLayer(let x, let y, let dx, let dy):
            m.clearSelection()
            guard case .layer? = m.item(at: Point(x: x, y: y)) else { return }
            h.drag((x, y), (x + dx, y + dy))
        case .importImage(let width, let height, let underMask):
            // addImageLayer centers an image that fits at scale 1; with even margins its pixels
            // land on whole document pixels, so a patch can sit exactly under a box. A patched
            // import is as large as the canvas (up to 400 × 300), so every box on it fits.
            let canvas = m.document.canvasSize
            var width = width, height = height
            if underMask != nil, canvas.width <= 400, canvas.height <= 300 {
                (width, height) = (Int(canvas.width), Int(canvas.height))
            }
            let left = (canvas.width - Double(width)) / 2, top = (canvas.height - Double(height)) / 2
            var secrets: [FixtureRect] = []
            if let underMask, !m.document.masks.isEmpty, left >= 0, top >= 0, left == left.rounded(),
                top == top.rounded()
            {
                let box = m.document.masks[underMask % m.document.masks.count].outputRect
                let patch = FixtureRect(
                    x: Int(box.minX - left), y: Int(box.minY - top), width: Int(box.width), height: Int(box.height))
                if patch.x >= 0, patch.y >= 0, patch.x + patch.width <= width, patch.y + patch.height <= height {
                    secrets = [patch]
                }
            }
            _ = try? await fixture.importLayer(width: width, height: height, secrets: secrets, green: green)
        case .duplicate(let pick):
            guard let item = one(layers + annotations, pick) else { return }
            m.setSelection([item])
            m.duplicateSelection()
        case .delete(let pick):
            guard let item = one(layers + annotations, pick) else { return }
            m.setSelection([item])
            m.deleteSelection()
        case .reorder(let pick, let order):
            guard let item = one(layers + annotations, pick) else { return }
            m.setSelection([item])
            m.reorderSelection(order)
        case .layerOpacity(let pick, let opacity):
            guard case .layer(let id)? = one(layers, pick) else { return }
            m.setLayerOpacity(opacity, for: id)
        case .addRectangle(let x, let y, let width, let height):
            m.setFillColor(.yellow)
            m.selectTool(.rectangle)
            h.drag((x, y), (x + width, y + height))
        case .addText(let x, let y, let text):
            m.selectTool(.text)
            h.click(x, y)
            m.commitTextEditing(text)
        case .restyle(let pick, let lineWidth, let fontSize):
            guard let annotation = one(annotations, pick) else { return }
            m.setSelection([annotation])
            m.setLineWidth(lineWidth)
            m.setFontSize(fontSize)
        case .continuousRestyle(let pick, let widths):
            guard let annotation = one(annotations, pick) else { return }
            m.setSelection([annotation])
            let id = m.beginContinuousChange()
            for width in widths { m.setLineWidth(width) }
            m.endContinuousChange(id)
        case .nudgeAnnotation(let pick, let dx, let dy):
            guard let annotation = one(annotations, pick) else { return }
            m.setSelection([annotation])
            m.nudgeSelection(dx: dx, dy: dy)
        case .addMagnifier(let x, let y, let width, let height):
            m.selectTool(.magnifier)
            h.drag((x, y), (x + width, y + height))
        case .nudgeCallout(let pick, let dx, let dy):
            guard let callout = one(callouts, pick) else { return }
            m.setSelection([callout])
            m.nudgeSelection(dx: dx, dy: dy)
        case .fitCanvas:
            m.fitCanvasToContent()
        case .crop(let x, let y, let width, let height):
            m.selectTool(.crop)
            h.drag((x, y), (x + width, y + height))
        case .resetCrop:
            m.setCrop(nil)
        case .undo:
            m.undo()
        case .redo:
            m.redo()
        case .togglePreview:
            m.setShowsOutputPreview(!m.showsOutputPreview)
        case .zoomPan(let zoom, let dx, let dy):
            m.setZoom(zoom)
            m.pan(dx: dx, dy: dy)
        case .alignMixed(let picks, let alignment):
            let masks = m.document.masks.map { EditorItemID.mask($0.id) }
            let candidates = layers + masks + annotations
            let picked = candidates.enumerated().filter { picks & (1 << ($0.offset % 6)) != 0 }.map(\.element)
            let frames = picked.compactMap { item in m.frame(of: item).map { (item, $0) } }
            guard let first = frames.first else { return }
            let reference =
                frames.count == 1 ? m.document.canvasRect : frames.dropFirst().reduce(first.1) { $0.union($1.1) }
            // A mixed edit only: an align that moves no layer is an explicit mask move, so skip it
            // rather than run and undo it (which would leave it on the redo stack, R6-03).
            let movesLayer = frames.contains { item, frame in
                guard case .layer = item else { return false }
                switch alignment {
                case .left: return frame.minX != reference.minX
                case .horizontalCenter: return frame.midX != reference.midX
                case .right: return frame.maxX != reference.maxX
                case .top: return frame.minY != reference.minY
                case .verticalCenter: return frame.midY != reference.midY
                case .bottom: return frame.maxY != reference.maxY
                }
            }
            guard movesLayer else { return }
            m.setSelection(Set(picked))
            m.align(alignment)
        case .nudgeMixed(let pick, let dx):
            guard let layer = one(layers, pick), let mask = m.document.masks.first?.id else { return }
            m.setSelection([layer, .mask(mask)])
            m.nudgeSelection(dx: dx, dy: 0)
        case .zoomedDragMixed(let pick, let viewDX):
            guard let layer = one(layers, pick), let mask = m.document.masks.first?.id,
                let frame = m.frame(of: layer)
            else { return }
            m.setSelection([layer, .mask(mask)])
            m.setZoom(8)
            let press = Point<DocumentSpace>(x: frame.midX, y: frame.midY)
            guard m.item(at: press) == layer else { return }
            let a = m.viewport.viewPoint(press)
            h.dragInView(a, Point(x: a.x + viewDX, y: a.y), steps: 1)
        }
        m.selectTool(.select)
    }
}

/// A small deterministic generator, so a failing seed replays exactly.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
