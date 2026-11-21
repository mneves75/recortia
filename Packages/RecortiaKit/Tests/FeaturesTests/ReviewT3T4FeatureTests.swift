import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Features

// Independent acceptance review of trains T3 and T4 (program 2026-11), written from the
// requirements: a secure mask never uncovers what it hides through any sequence of turns, mirrors,
// crops and layer moves; Text Only reads lines correctly on a turned or mirrored image and is told
// every pixel an earlier mask hides; whole-pixel documents survive four turns byte for byte; a
// click-through pin can always be recovered.

/// SplitMix64, so every failing sequence reproduces from its seed.
private struct SequenceRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Review T3/T4: secure masks through transform sequences (A-10, RED-01)")
@MainActor
struct ReviewTransformSequenceTests {
    enum Step: CustomStringConvertible {
        case image(ImageTransform), layer(ImageTransform), crop, resetCrop, moveLayer

        static let all: [Step] =
            ImageTransform.allCases.map(Step.image) + ImageTransform.allCases.map(Step.layer) + [
                .crop, .resetCrop, .moveLayer,
            ]

        var description: String {
            switch self {
            case .image(let t): "image \(t)"
            case .layer(let t): "layer \(t)"
            case .crop: "crop"
            case .resetCrop: "reset crop"
            case .moveLayer: "move layer"
            }
        }
    }

    @Test("No sequence of image turns, layer turns, crops and layer moves exports a masked pixel; Undo restores all")
    func sequencesNeverUncover() async throws {
        let baseSecret = FixtureRect(x: 40, y: 40, width: 30, height: 20)
        let layerSecret = FixtureRect(x: 20, y: 10, width: 12, height: 8)
        let fixture = try await SecretExport(secrets: [baseSecret])
        let h = fixture.harness, m = h.model
        #expect(
            fixture.secretPixels(in: try await fixture.exported()) == 600, "positive control: the secret is exported")
        m.selectTool(.redact)
        h.drag((38, 38), (72, 62))
        m.clearSelection()
        // Drawn before the layer exists, so only its box protects the layer's secret at first.
        h.drag((218, 158), (234, 170))
        m.clearSelection()
        m.selectTool(.select)
        let id = try await fixture.addLayer(width: 100, height: 75, secrets: [layerSecret])
        m.setFrame(Rect(x: 200, y: 150, width: 100, height: 75), for: .layer(id))
        let asset = try #require(m.document.layers.last?.assetID)
        #expect(m.document.masks.count == 2)
        #expect(m.document.masks[1].sourceRegions[asset] == nil, "the late layer is not bound to the second box yet")
        #expect(fixture.secretPixels(in: try await fixture.exported()) == 0)

        let baseline = m.document, baselineUndo = m.session.undoCount
        var random = SequenceRandom(state: 0x7_4A10)
        for sequence in 0..<60 {
            var applied: [Step] = []
            for _ in 0..<5 {
                let step = Step.all.randomElement(using: &random)!
                applied.append(step)
                switch step {
                case .image(let t): m.transformImage(t)
                case .layer(let t):
                    m.setSelection([.layer(id)])
                    m.transformSelectedLayers(t)
                case .crop:
                    let c = m.document.canvasRect
                    m.setCrop(Rect(x: c.minX + 30, y: c.minY + 30, width: c.width - 60, height: c.height - 60))
                case .resetCrop: m.setCrop(nil)
                case .moveLayer:
                    if let frame = m.frame(of: .layer(id)) {
                        m.setFrame(frame.offsetBy(dx: 17, dy: -11), for: .layer(id))
                    }
                }
                let leaked = fixture.secretPixels(in: try await fixture.exported())
                #expect(leaked == 0, "sequence \(sequence) \(applied): \(leaked) secret pixels exported")
            }
            while m.session.undoCount > baselineUndo { m.undo() }
            #expect(m.document == baseline, "sequence \(sequence) \(applied): Undo did not restore the document")
        }
    }
}

@Suite("Review T3/T4: Text Only on a turned or mirrored image (A-6, A-10)")
@MainActor
struct ReviewTextRedactionTransformTests {
    @Test("Lines read from source pixels land over the right document pixels after any whole-image transform")
    func linesFollowTheTransform() async throws {
        let secret = FixtureRect(x: 100, y: 100, width: 60, height: 12)
        let size = PixelSize(width: 400, height: 300)
        for transform in [ImageTransform?.none] + ImageTransform.allCases.map(Optional.some) {
            let label = String(describing: transform)
            let fixture = try await SecretExport(secrets: [secret])
            let h = fixture.harness, m = h.model
            if let transform { m.transformImage(transform) }
            let map = try #require(m.document.layers.first).sourceToDocument(assetSize: size)
            let shown = try #require(
                Rect<DocumentSpace>.bounding(
                    PixelRect(x: secret.x, y: secret.y, width: secret.width, height: secret.height).asRect.corners
                        .map(map.apply)))
            let cover = shown.insetBy(dx: -20, dy: -20)
            h.sensitiveText.lines = [PixelRect(x: 98, y: 98, width: 64, height: 16)]
            m.setRedactsTextOnly(true)
            m.selectTool(.redact)
            h.drag((cover.minX, cover.minY), (cover.maxX, cover.maxY))
            await waitFor("lines landed, \(label)") { !m.isMaskingPending }
            #expect(
                h.sensitiveText.lineRequests == [PixelRect(x: 80, y: 80, width: 100, height: 52)],
                "\(label): the source area under the cover")
            #expect(m.notice == .textLinesCovered(1), "\(label): \(String(describing: m.notice))")
            #expect(m.document.masks.count == 1, "\(label)")
            let pixels = try await fixture.exported()
            #expect(fixture.secretPixels(in: pixels) == 0, "\(label): the line's secret is hidden")
            let rect = FixtureRect(
                x: Int(cover.minX), y: Int(cover.minY), width: Int(cover.width), height: Int(cover.height))
            #expect(
                fixture.uncoveredPixels(in: pixels, rect) > 0,
                "\(label): positive control, the cover was replaced by the line and the rest shows")
        }
    }

    @Test("A mask whose binding a layer mirror carried out of its box still hides those pixels from recognition")
    func hiddenIncludesCarriedBindings() async throws {
        let a = ImageAssetInfo(id: AssetID(), pixelSize: PixelSize(width: 400, height: 300), origin: .imported)
        let layer = ImageLayer(assetID: a.id)
        let document = Document(
            assets: [a.id: a], canvasSize: Size(width: 400, height: 300), layers: [layer],
            masks: [
                SecureMask(
                    outputRect: Rect(x: 30, y: 60, width: 100, height: 20),
                    sourceRegions: [a.id: [PixelRect(x: 30, y: 60, width: 100, height: 20)]], fill: .black)
            ])
        let h = EditorHarness(session: DocumentSession(document: document))
        let m = h.model
        m.setSelection([.layer(layer.id)])
        m.transformSelectedLayers(.flipHorizontal)
        #expect(m.document.layers[0].placement.mirrored, "positive control: the layer is mirrored")
        h.sensitiveText.pending = Pending<Void>()
        m.setRedactsTextOnly(true)
        m.selectTool(.redact)
        // The bound pixels (source x 30..<130) now show at document x 270..<370.
        h.drag((260, 40), (380, 100))
        await waitFor("recognition started") { h.sensitiveText.pending?.waiterCount == 1 }
        let hidden = Set(try #require(h.sensitiveText.hiddenRequests.last))
        #expect(hidden.contains(PixelRect(x: 30, y: 60, width: 100, height: 20)), "the carried binding: \(hidden)")
        #expect(hidden.contains(PixelRect(x: 270, y: 60, width: 100, height: 20)), "the pixels now under the box")
        h.sensitiveText.pending?.resolve(())
        await waitFor("recognition settled") { !m.isMaskingPending }
    }
}

@Suite("Review T3/T4: whole-pixel documents survive turns and mirrors byte for byte (A-10, A-11)")
@MainActor
struct ReviewTransformBytesTests {
    static func document(withText: Bool) -> Document {
        let a = ImageAssetInfo(id: AssetID(), pixelSize: PixelSize(width: 401, height: 299), origin: .imported)
        let b = ImageAssetInfo(id: AssetID(), pixelSize: PixelSize(width: 51, height: 33), origin: .imported)
        let style = Annotation.Style(stroke: RGBA(r: 255, g: 0, b: 0))
        var annotations = [
            Annotation(
                kind: .arrow(
                    start: Point(x: 10, y: 20), end: Point(x: 200, y: 40), control: Point(x: 90, y: 150), head: .double),
                style: style),
            Annotation(kind: .arrow(start: Point(x: 5, y: 5), end: Point(x: 60, y: 7)), style: style),
            Annotation(kind: .rectangle(Rect(x: 30, y: 40, width: 50, height: 21)), style: style),
            Annotation(
                kind: .freehand([Point(x: 1, y: 2), Point(x: 30, y: 9), Point(x: 61, y: 3)], smoothed: true),
                style: style),
            Annotation(kind: .highlighter([Point(x: 100, y: 100), Point(x: 180, y: 101)]), style: style),
            Annotation(kind: .step(center: Point(x: 300, y: 200), number: 3), style: style),
        ]
        if withText {
            annotations.append(
                Annotation(kind: .text(.init(origin: Point(x: 40, y: 250), string: "Recortia 42")), style: style))
        }
        return Document(
            assets: [a.id: a, b.id: b], canvasSize: Size(width: 401, height: 299),
            layers: [
                ImageLayer(assetID: a.id),
                ImageLayer(
                    assetID: b.id, placement: LayerPlacement(translation: Point(x: 37, y: 12), scale: 2),
                    sourceCrop: PixelRect(x: 1, y: 2, width: 40, height: 30)),
            ],
            annotations: annotations,
            masks: [
                SecureMask(
                    outputRect: Rect(x: 50, y: 60, width: 33, height: 17),
                    sourceRegions: [a.id: [PixelRect(x: 50, y: 60, width: 33, height: 17)]], fill: .black)
            ],
            obfuscations: [
                CosmeticObfuscation(rect: Rect(x: 220, y: 30, width: 40, height: 40), style: .blur(radius: 8))
            ],
            crop: Rect(x: 3, y: 4, width: 390, height: 280),
            presentation: Presentation(padding: 12, aspect: .square),
            callouts: [
                Callout(kind: .spotlight(Rect(x: 10, y: 10, width: 20, height: 30), dimOpacity: 0.4)),
                Callout(
                    kind: .magnifier(
                        source: Rect(x: 100, y: 100, width: 10, height: 10),
                        destination: Rect(x: 150, y: 150, width: 40, height: 40))),
            ])
    }

    static func bytes(_ document: Document) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(document), as: UTF8.self)
    }

    @Test("Four turns or two mirrors give back the same bytes, with no key added on the way", arguments: [false, true])
    func roundTripBytes(withText: Bool) throws {
        let original = Self.document(withText: withText)
        let before = try Self.bytes(original)
        #expect(!before.contains("mirrored") && !before.contains("\"head\":\"filled\""))
        for transform in ImageTransform.allCases {
            var document = original
            for turn in 1...(transform.swapsSides ? 4 : 2) {
                try EditorModel.transform(&document, transform)
                let decoded = try JSONDecoder().decode(Document.self, from: Data(try Self.bytes(document).utf8))
                #expect(decoded == document, "\(transform) ×\(turn) does not round-trip through Codable")
            }
            let after = try Self.bytes(document)
            #expect(document == original, "\(transform) (text: \(withText)): the document drifted")
            #expect(after == before, "\(transform) (text: \(withText)): the bytes changed")
        }
    }
}

@Suite("Review T3/T4: a click-through pin is always recoverable (ADR-007 amendment)")
@MainActor
struct ReviewPinRecoveryTests {
    @Test(
        "Under any sequence of pin actions: locked implies on top, Unlock All is offered exactly when needed and frees all"
    )
    func invariantsHold() throws {
        let h = PinsHarness()
        var random = SequenceRandom(state: 0x91_0007)
        for step in 0..<3_000 {
            let ids = h.model.pins.map(\.id)
            let before = h.model.pins.map(\.keepsOnTop)
            var unlocked = false
            switch Int.random(in: 0..<7, using: &random) {
            case 0 where ids.count < 4:
                let id = try h.model.add(try #require(makeImage()), source: nil, displayScale: 1)
                let pin = try #require(h.model.pin(for: id))
                #expect(!pin.keepsOnTop && !pin.isClickThrough, "step \(step): a new pin starts normal and interactive")
            case 1 where !ids.isEmpty: h.model.close(ids.randomElement(using: &random)!)
            case 2 where !ids.isEmpty:
                h.model.setKeepsOnTop(.random(using: &random), for: ids.randomElement(using: &random)!)
            case 3, 4:
                if let id = ids.randomElement(using: &random) {
                    h.model.setClickThrough(.random(using: &random), for: id)
                }
            case 5:
                h.model.unlockAll()
                unlocked = true
            case 6 where step % 50 == 0: h.model.closeAll()
            default: break
            }
            let pins = h.model.pins
            #expect(pins.allSatisfy { !$0.isClickThrough || $0.keepsOnTop }, "step \(step): a locked pin below the top")
            #expect(h.model.hasClickThroughPin == pins.contains(where: \.isClickThrough), "step \(step)")
            if unlocked {
                #expect(!h.model.hasClickThroughPin, "step \(step): Unlock All left a pin locked")
                #expect(pins.map(\.keepsOnTop) == before, "step \(step): Unlock All changed a window level")
            }
        }
    }
}
