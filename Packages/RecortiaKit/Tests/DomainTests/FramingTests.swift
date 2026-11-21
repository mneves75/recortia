import Foundation
import Testing

@testable import Domain

// Failure modes (FR-13, A-8): an aspect preset that shrinks the padding, misses its ratio by a
// rounding pixel or grows the output more than it needs; a content origin off centre; a framed
// preview rectangle that does not cover the rendered output; a document written before presets
// that no longer decodes or decodes with a different framing.
@Suite("Framing aspect presets and compatibility (FR-13)")
struct FramingTests {
    private static func document(width: Double = 90, height: Double = 60, presentation: Presentation) -> Document {
        let asset = ImageAssetInfo(
            id: AssetID(), pixelSize: PixelSize(width: Int(width), height: Int(height)), origin: .imported)
        var document = Document(asset: asset)
        document.presentation = presentation
        return document
    }

    @Test(
        "Each preset is the smallest exact multiple of its ratio that keeps the padding",
        arguments: [
            (FramingAspect.free, 120, 90), (.square, 120, 120), (.portrait4x5, 120, 150), (.landscape16x9, 160, 90),
            (.portrait9x16, 126, 224), (.landscape3x2, 135, 90),
        ])
    func presetSize(aspect: FramingAspect, width: Int, height: Int) {
        let document = Self.document(presentation: Presentation(padding: 15, aspect: aspect))
        let frame = document.outputFrame(exportScale: 1)
        #expect(frame.pixelSize == PixelSize(width: width, height: height))
        #expect(document.outputPixelSize(exportScale: 1) == frame.pixelSize)
        if let ratio = aspect.ratio {
            #expect(width * ratio.height == height * ratio.width, "exact ratio")
        }
        // Padding is a minimum on every side.
        #expect(frame.contentOriginX >= 15 && frame.contentOriginY >= 15)
        #expect(Double(width) - frame.contentOriginX - 90 >= 15)
        #expect(Double(height) - frame.contentOriginY - 60 >= 15)
    }

    @Test("Free keeps today's size and origin; a preset centres the content box on whole pixels")
    func origin() {
        let free = Self.document(presentation: Presentation(padding: 15)).outputFrame(exportScale: 1)
        #expect(free.contentOriginX == 15 && free.contentOriginY == 15)
        let tall = Self.document(presentation: Presentation(padding: 15, aspect: .portrait9x16))
            .outputFrame(exportScale: 1)
        #expect(tall.contentOriginX == 18 && tall.contentOriginY == 82)
        // 91 × 60 content in a 1:1 frame of 121: (121 - 91) / 2 = 15, (121 - 60) / 2 = 30.5 → 30.
        let odd = Self.document(width: 91, presentation: Presentation(padding: 15, aspect: .square))
            .outputFrame(exportScale: 1)
        #expect(odd.pixelSize == PixelSize(width: 121, height: 121))
        #expect(odd.contentOriginX == 15 && odd.contentOriginY == 30)
    }

    @Test("Export scale and resize scale apply before the ratio, so the ratio stays exact")
    func scaled() {
        var document = Self.document(presentation: Presentation(padding: 15, aspect: .landscape16x9))
        document.resizeScale = 0.5
        let frame = document.outputFrame(exportScale: 3)
        // (90 + 30) × 1.5 = 180, (60 + 30) × 1.5 = 135 → 16:9 multiple 15 → 240 × 135.
        #expect(frame.pixelSize == PixelSize(width: 240, height: 135))
        #expect(frame.contentOriginX == 52 && frame.contentOriginY == 22)
    }

    @Test("The framed rectangle is the output in document units, centred on the content")
    func framedRect() {
        let document = Self.document(presentation: Presentation(padding: 15, aspect: .square))
        #expect(document.framedRect(exportScale: 1) == Rect(x: -15, y: -30, width: 120, height: 120))
        let free = Self.document(presentation: Presentation(padding: 10))
        #expect(free.framedRect(exportScale: 1) == Rect(x: -10, y: -10, width: 110, height: 80))
    }

    @Test("An absurd padding fails closed to an empty size instead of overflowing")
    func overflow() {
        let document = Self.document(presentation: Presentation(padding: 1e12, aspect: .portrait9x16))
        #expect(document.outputPixelSize(exportScale: 1).isEmpty)
    }

    // Encoded by the 0.14-era code (before aspect presets) with sorted keys, captured on
    // 2026-11-21 from commit 887613b.
    static let documentBeforePresets = #"""
        {"annotations":[],"assets":[{"raw":"00000000-0000-0000-0000-0000000000A1"},{"id":{"raw":"00000000-0000-0000-0000-0000000000A1"},"origin":{"imported":{}},"pixelSize":{"height":30,"width":40}}],"callouts":[],"canvasSize":{"height":30,"width":40},"id":{"raw":"00000000-0000-0000-0000-0000000000D1"},"layers":[{"assetID":{"raw":"00000000-0000-0000-0000-0000000000A1"},"id":{"raw":"E479BCD3-370D-49BD-B4F4-B94F82D23D09"},"opacity":1,"placement":{"rotation":0,"scale":1,"translation":{"x":0,"y":0}}}],"masks":[],"obfuscations":[],"presentation":{"background":{"linearGradient":{"angleDegrees":135,"from":{"a":255,"b":30,"g":20,"r":10},"to":{"a":255,"b":220,"g":210,"r":200}}},"cornerRadius":12,"padding":24,"shadow":{"offsetY":12,"opacity":0.35,"radius":24}},"resizeScale":1}
        """#
    static let plainBeforePresets = #"{"background":{"none":{}},"cornerRadius":0,"padding":0}"#
    static let solidBeforePresets =
        #"{"background":{"solid":{"_0":{"a":255,"b":3,"g":2,"r":1}}},"cornerRadius":0,"padding":0}"#

    @Test("A document written before presets decodes unchanged, as Free with balance on")
    func oldDocumentDecodes() throws {
        let document = try JSONDecoder().decode(Document.self, from: Data(Self.documentBeforePresets.utf8))
        #expect(
            document.presentation
                == Presentation(
                    background: .linearGradient(
                        from: RGBA(r: 10, g: 20, b: 30), to: RGBA(r: 200, g: 210, b: 220), angleDegrees: 135),
                    padding: 24, cornerRadius: 12, shadow: Presentation.Shadow()))
        #expect(document.presentation.aspect == .free && document.presentation.balancesContent)
        #expect(document.outputPixelSize(exportScale: 1) == PixelSize(width: 88, height: 78))
        let plain = try JSONDecoder().decode(Presentation.self, from: Data(Self.plainBeforePresets.utf8))
        #expect(plain == .plain && plain.isPlain)
        let solid = try JSONDecoder().decode(Presentation.self, from: Data(Self.solidBeforePresets.utf8))
        #expect(solid == Presentation(background: .solid(RGBA(r: 1, g: 2, b: 3))))
    }

    @Test("Aspect, balance and the radial gradient survive a round trip")
    func roundTrip() throws {
        let framing = Presentation(
            background: .radialGradient(center: .white, edge: RGBA(r: 1, g: 2, b: 3)), padding: 8,
            aspect: .portrait4x5, balancesContent: false)
        let decoded = try JSONDecoder().decode(Presentation.self, from: JSONEncoder().encode(framing))
        #expect(decoded == framing)
        #expect(!decoded.isPlain && !decoded.centresOpaqueContent)
        #expect(Presentation(aspect: .square).centresOpaqueContent)
        #expect(!Presentation(aspect: .free).centresOpaqueContent)
    }

    @Test("A saved background wins for every capture; a saved None keeps a window capture's background")
    func captureFraming() {
        let framing = Presentation(background: .solid(.white), padding: 20, aspect: .square)
        let geometry = CaptureGeometry(
            source: .window(id: 1, displayID: 1), desktopBounds: Rect(x: 0, y: 0, width: 4, height: 4),
            pointPixelScale: 1, pixelSize: PixelSize(width: 4, height: 4), capturedAt: Date(timeIntervalSince1970: 0))
        let asset = ImageAssetInfo(
            id: AssetID(), pixelSize: PixelSize(width: 4, height: 4), origin: .captured(geometry))
        let window = Document(capture: asset, windowBackground: .solid(.black))
        #expect(window.presentation == Presentation(background: .solid(.black)))
        let framed = Document(capture: asset, windowBackground: .solid(.black), defaultFraming: framing)
        #expect(framed.presentation == framing)

        // A saved framing with no background keeps the window background; everything else is saved.
        let bare = Presentation(padding: 20, aspect: .square)
        var expected = bare
        expected.background = .solid(.black)
        let kept = Document(capture: asset, windowBackground: .solid(.black), defaultFraming: bare)
        #expect(kept.presentation == expected)
        let transparent = Document(capture: asset, windowBackground: .transparent, defaultFraming: bare)
        #expect(transparent.presentation == bare)
        let region = ImageAssetInfo(
            id: AssetID(), pixelSize: PixelSize(width: 4, height: 4),
            origin: .captured(
                CaptureGeometry(
                    source: .region(displayID: 1), desktopBounds: geometry.desktopBounds, pointPixelScale: 1,
                    pixelSize: geometry.pixelSize, capturedAt: geometry.capturedAt)))
        #expect(Document(capture: region, windowBackground: .solid(.black), defaultFraming: bare).presentation == bare)
    }
}
