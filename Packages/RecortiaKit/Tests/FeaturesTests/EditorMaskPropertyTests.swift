import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Features

// Acceptance gate for the mask rule (R4): no editor operation other than an explicit mask edit may
// make the export depend on pixels a mask protected. Two documents differ only inside the masked
// patches, on the bottom image (bound when each mask was made) and on a pasted image (one patch
// protected only by the box over it when it was pasted). The same seeded sequence of non-mask
// edits must leave their exports identical after every step. Setup is outside Undo's reach:
// undoing a mask's creation is an explicit mask edit.
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
                for fixture in variants { await step.apply(to: fixture) }
                let red = try? await variants[0].exported()
                let other = try? await variants[1].exported()
                if red != nil { compared += 1 }
                guard red == other else {
                    let differing = zip(red?.bytes ?? [], other?.bytes ?? []).filter { $0 != $1 }.count
                    Issue.record(
                        """
                        seed \(seed), step \(index + 1) of \(steps): the export reveals protected pixels \
                        (\(differing) differing bytes; exported \(red != nil) and \(other != nil))
                        """)
                    return
                }
            }
        }
        #expect(compared > 100, "most steps produce an export to compare")
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
private enum Step: CustomStringConvertible {
    case nudgeLayer(pick: Int, dx: Double, dy: Double)
    case setLayerFrame(pick: Int, x: Double, y: Double, factor: Double)
    case layerScale(pick: Int, scale: Double)
    case sideBySide
    case align(picks: Int, alignment: EditorAlignment)
    case dragLayer(x: Double, y: Double, dx: Double, dy: Double)
    case paste(width: Int, height: Int)
    case duplicateLayer(pick: Int)
    case addRectangle(x: Double, y: Double, width: Double, height: Double)
    case nudgeAnnotation(pick: Int, dx: Double, dy: Double)
    case addMagnifier(x: Double, y: Double, width: Double, height: Double)
    case nudgeCallout(pick: Int, dx: Double, dy: Double)
    case fitCanvas
    case crop(x: Double, y: Double, width: Double, height: Double)
    case undo
    case redo
    case togglePreview
    case zoomPan(zoom: Double, dx: Double, dy: Double)

    var description: String {
        switch self {
        case .nudgeLayer(let pick, let dx, let dy): "nudgeLayer(\(pick), \(dx), \(dy))"
        case .setLayerFrame(let pick, let x, let y, let factor): "setLayerFrame(\(pick), \(x), \(y), ×\(factor))"
        case .layerScale(let pick, let scale): "layerScale(\(pick), \(scale))"
        case .sideBySide: "sideBySide"
        case .align(let picks, let alignment): "align(\(picks), \(alignment))"
        case .dragLayer(let x, let y, let dx, let dy): "dragLayer(\(x), \(y), +\(dx), +\(dy))"
        case .paste(let width, let height): "paste(\(width)×\(height))"
        case .duplicateLayer(let pick): "duplicateLayer(\(pick))"
        case .addRectangle(let x, let y, let w, let h): "addRectangle(\(x), \(y), \(w), \(h))"
        case .nudgeAnnotation(let pick, let dx, let dy): "nudgeAnnotation(\(pick), \(dx), \(dy))"
        case .addMagnifier(let x, let y, let w, let h): "addMagnifier(\(x), \(y), \(w), \(h))"
        case .nudgeCallout(let pick, let dx, let dy): "nudgeCallout(\(pick), \(dx), \(dy))"
        case .fitCanvas: "fitCanvas"
        case .crop(let x, let y, let w, let h): "crop(\(x), \(y), \(w), \(h))"
        case .undo: "undo"
        case .redo: "redo"
        case .togglePreview: "togglePreview"
        case .zoomPan(let zoom, let dx, let dy): "zoomPan(\(zoom), \(dx), \(dy))"
        }
    }

    static func random(using rng: inout SplitMix64) -> Step {
        func coordinate() -> Double { Double(Int.random(in: -25...200, using: &rng)) }
        func delta() -> Double { Double(Int.random(in: -60...60, using: &rng)) }
        func length() -> Double { Double(Int.random(in: 5...75, using: &rng)) }
        let pick = Int.random(in: 0..<64, using: &rng)
        switch Int.random(in: 0..<18, using: &rng) {
        case 0: return .nudgeLayer(pick: pick, dx: delta(), dy: delta())
        case 1:
            return .setLayerFrame(
                pick: pick, x: coordinate(), y: coordinate(), factor: Double.random(in: 0.4...1.6, using: &rng))
        case 2: return .layerScale(pick: pick, scale: Double.random(in: 0.3...2, using: &rng))
        case 3: return .sideBySide
        case 4: return .align(picks: pick, alignment: EditorAlignment.allCases.randomElement(using: &rng) ?? .left)
        case 5: return .dragLayer(x: coordinate(), y: coordinate(), dx: delta(), dy: delta())
        case 6:
            return .paste(width: Int.random(in: 20...100, using: &rng), height: Int.random(in: 20...75, using: &rng))
        case 7: return .duplicateLayer(pick: pick)
        case 8: return .addRectangle(x: coordinate(), y: coordinate(), width: length(), height: length())
        case 9: return .nudgeAnnotation(pick: pick, dx: delta(), dy: delta())
        case 10: return .addMagnifier(x: coordinate(), y: coordinate(), width: length(), height: length())
        case 11: return .nudgeCallout(pick: pick, dx: delta(), dy: delta())
        case 12: return .fitCanvas
        case 13: return .crop(x: coordinate(), y: coordinate(), width: length() * 2, height: length() * 2)
        case 14: return .undo
        case 15: return .redo
        case 16: return .togglePreview
        default: return .zoomPan(zoom: Double.random(in: 0.1...4, using: &rng), dx: delta(), dy: delta())
        }
    }

    @MainActor
    func apply(to fixture: SecretExport) async {
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
        case .paste(let width, let height):
            _ = try? await fixture.addLayer(width: width, height: height, secrets: [])
        case .duplicateLayer(let pick):
            guard let layer = one(layers, pick) else { return }
            m.setSelection([layer])
            m.duplicateSelection()
        case .addRectangle(let x, let y, let width, let height):
            m.setFillColor(.yellow)
            m.selectTool(.rectangle)
            h.drag((x, y), (x + width, y + height))
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
        case .undo:
            m.undo()
        case .redo:
            m.redo()
        case .togglePreview:
            m.setShowsOutputPreview(!m.showsOutputPreview)
        case .zoomPan(let zoom, let dx, let dy):
            m.setZoom(zoom)
            m.pan(dx: dx, dy: dy)
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
