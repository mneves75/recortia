import Domain
import Foundation
import Testing

// Independent acceptance review of trains T3 and T4 (program 2026-11). Each property is written
// from the requirement, not from the implementation: an independent oracle for WCAG, brute-force
// pixel footprints for mask coverage under every orientation, and invariants of region selection
// checked over many seeded cases instead of hand-picked ones.

/// SplitMix64: a deterministic generator, so every failure reproduces from its seed.
struct ReviewRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Review T3/T4: WCAG contrast against an independent oracle (A-7)")
struct ReviewContrastOracleTests {
    /// WCAG 2.2 "relative luminance" and "contrast ratio", restated from the definitions.
    static func oracleLuminance(_ c: RGBA) -> Double {
        func channel(_ v: UInt8) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    static func oracleRatio(_ x: RGBA, _ y: RGBA) -> Double {
        let (a, b) = (oracleLuminance(x), oracleLuminance(y))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    @Test("Black on white is exactly 21, a colour on itself is exactly 1")
    func extremes() throws {
        let white = RGBA(r: 255, g: 255, b: 255), black = RGBA(r: 0, g: 0, b: 0)
        #expect(try #require(ContrastRatio(foreground: black, background: white)).ratio == 21)
        #expect(try #require(ContrastRatio(foreground: white, background: black)).ratio == 21)
        for v: UInt8 in [0, 1, 10, 11, 127, 128, 254, 255] {
            let grey = RGBA(r: v, g: v, b: v)
            #expect(try #require(ContrastRatio(foreground: grey, background: grey)).ratio == 1)
        }
    }

    @Test("Every pair matches the oracle, is symmetric, lies in 1...21, and AA/AAA use the unrounded ratio")
    func matchesOracle() throws {
        var random = ReviewRandom(seed: 0xC0_1012)
        for _ in 0..<5_000 {
            let f = RGBA(
                r: .random(in: 0...255, using: &random), g: .random(in: 0...255, using: &random),
                b: .random(in: 0...255, using: &random))
            let g = RGBA(
                r: .random(in: 0...255, using: &random), g: .random(in: 0...255, using: &random),
                b: .random(in: 0...255, using: &random))
            let one = try #require(ContrastRatio(foreground: f, background: g))
            let two = try #require(ContrastRatio(foreground: g, background: f))
            let expected = Self.oracleRatio(f, g)
            #expect(abs(one.ratio - expected) <= 1e-12, "\(f) on \(g)")
            #expect(one.ratio == two.ratio, "order must not matter: \(f), \(g)")
            #expect((1...21).contains(one.ratio))
            #expect(one.shownRatio <= one.ratio && one.ratio - one.shownRatio < 0.01)
            #expect(one.passes(.aa, largeText: false) == (expected >= 4.5))
            #expect(one.passes(.aa, largeText: true) == (expected >= 3))
            #expect(one.passes(.aaa, largeText: false) == (expected >= 7))
            #expect(one.passes(.aaa, largeText: true) == (expected >= 4.5))
        }
    }

    @Test("Luminance is monotonic in each channel and the WCAG 2.0 threshold picks the same branch for 8-bit input")
    func luminanceShape() {
        var previous = -1.0
        for v in 0...255 {
            let l = RGBA(r: UInt8(v), g: UInt8(v), b: UInt8(v)).relativeLuminance
            #expect(l > previous, "grey \(v)")
            previous = l
            let s = Double(v) / 255
            #expect((s <= 0.04045) == (s <= 0.03928), "8-bit value \(v) changes branch between WCAG 2.0 and 2.1")
        }
        #expect(abs(RGBA(r: 255, g: 255, b: 255).relativeLuminance - 1) < 1e-15)
    }

    @Test("Translucent colours have no WCAG ratio (planted control: the same colours opaque do)")
    func translucentRefused() {
        let half = RGBA(r: 10, g: 10, b: 10, a: 128)
        #expect(ContrastRatio(foreground: half, background: .white) == nil)
        #expect(ContrastRatio(foreground: .white, background: half) == nil)
        #expect(ContrastRatio(foreground: half.withAlpha(255), background: .white) != nil)
    }
}

@Suite("Review T3/T4: mask coverage under every turn and mirror, with a source crop (A-10, RED)")
struct ReviewMirrorCoverageTests {
    /// Every visible source pixel whose document footprint overlaps `rect` with positive area.
    static func touchedPixels(of layer: ImageLayer, assetSize: PixelSize, by rect: Rect<DocumentSpace>) -> [(
        Int, Int
    )] {
        let map = layer.sourceToDocument(assetSize: assetSize)
        let visible = layer.visibleSourceRect(assetSize: assetSize)
        var touched: [(Int, Int)] = []
        for y in visible.y..<visible.maxY {
            for x in visible.x..<visible.maxX {
                let corners = PixelRect(x: x, y: y, width: 1, height: 1).asRect.corners.map(map.apply)
                guard let footprint = Rect<DocumentSpace>.bounding(corners) else { continue }
                if let overlap = footprint.intersection(rect), overlap.width > 1e-9, overlap.height > 1e-9 {
                    touched.append((x, y))
                }
            }
        }
        return touched
    }

    @Test("A box binds every source pixel it overlaps, for each quarter turn, mirror, scale and source crop")
    func coverageIsConservative() throws {
        let assetSize = PixelSize(width: 23, height: 17)
        let asset = ImageAssetInfo(id: AssetID(), pixelSize: assetSize, origin: .imported)
        let crops: [PixelRect?] = [nil, PixelRect(x: 3, y: 2, width: 15, height: 11)]
        let boxes = [
            Rect<DocumentSpace>(x: 41, y: 33, width: 9, height: 4),
            Rect<DocumentSpace>(x: 38.5, y: 29.25, width: 6.5, height: 13.75),
            Rect<DocumentSpace>(x: 0, y: 0, width: 45, height: 36),
        ]
        var checked = 0
        for mirrored in [false, true] {
            for quarter in 0..<4 {
                for scale in [1.0, 2.0] {
                    for crop in crops {
                        let placement = LayerPlacement(
                            translation: Point(x: 40, y: 30), scale: scale, rotation: Double(quarter) * .pi / 2,
                            mirrored: mirrored)
                        let layer = ImageLayer(assetID: asset.id, placement: placement, sourceCrop: crop)
                        let document = Document(
                            assets: [asset.id: asset], canvasSize: Size(width: 120, height: 120), layers: [layer])
                        for box in boxes {
                            let covered = try document.coveredSourceRect(of: layer, by: box)
                            let touched = Self.touchedPixels(of: layer, assetSize: assetSize, by: box)
                            let label =
                                "mirrored \(mirrored), \(quarter)/4 turn, scale \(scale), crop \(String(describing: crop)), box \(box)"
                            if touched.isEmpty {
                                #expect(covered == nil || covered?.isEmpty == false, "\(label)")
                                continue
                            }
                            let region = try #require(covered, "\(label): overlapped pixels left unbound")
                            let missed = touched.filter { !region.contains(x: $0.0, y: $0.1) }
                            #expect(missed.isEmpty, "\(label): \(missed.count) overlapped pixels left unbound")
                            if let crop {
                                #expect(
                                    region.x >= crop.x && region.y >= crop.y && region.maxX <= crop.maxX
                                        && region.maxY <= crop.maxY, "\(label): binding outside the visible crop")
                            }
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked > 40, "positive control: the sweep reached overlapping boxes")
    }

    @Test("A mirror maps the visible source onto the same document rectangle, reversed left to right")
    func mirrorKeepsBounds() {
        let size = PixelSize(width: 23, height: 17)
        let crop = PixelRect(x: 3, y: 2, width: 15, height: 11)
        for quarter in 0..<4 {
            let plain = ImageLayer(
                assetID: AssetID(),
                placement: LayerPlacement(translation: Point(x: 5, y: 7), rotation: Double(quarter) * .pi / 2),
                sourceCrop: crop)
            var mirrored = plain
            mirrored.placement.mirrored = true
            #expect(plain.documentBounds(assetSize: size) == mirrored.documentBounds(assetSize: size))
            // The visible top-left source corner lands where the plain layer puts the top-right one.
            let left = Point<SourcePixelSpace>(x: Double(crop.x), y: Double(crop.y))
            let right = Point<SourcePixelSpace>(x: Double(crop.maxX), y: Double(crop.y))
            #expect(
                mirrored.sourceToDocument(assetSize: size).apply(left)
                    == plain.sourceToDocument(assetSize: size).apply(right), "\(quarter)/4 turn")
        }
    }
}

@Suite("Review T3/T4: region selection at display edges with an aspect lock (FR-02, A-4)")
struct ReviewRegionPrecisionPropertyTests {
    /// A secondary display left of and above the main one: negative, fractional origin.
    static let display = Rect<DesktopSpace>(x: -1512.5, y: -200, width: 1512, height: 982)

    static func randomPoint(_ random: inout ReviewRandom, inside bounds: Rect<DesktopSpace>, slack: Double)
        -> Point<DesktopSpace>
    {
        Point(
            x: .random(in: (bounds.minX - slack)...(bounds.maxX + slack), using: &random),
            y: .random(in: (bounds.minY - slack)...(bounds.maxY + slack), using: &random))
    }

    @Test("Every drag ends inside the display, and a locked ratio holds exactly, near every edge and guide")
    func dragStaysInsideAndKeepsRatio() {
        var random = ReviewRandom(seed: 0xA4_0001)
        let bounds = Self.display
        for n in 0..<20_000 {
            // Anchors often sit on or near an edge; pointers often leave the display.
            let anchor: Point<DesktopSpace>
            if n % 3 == 0 {
                let edgeX = [bounds.minX, bounds.maxX, bounds.minX + 2, bounds.maxX - 2].randomElement(using: &random)!
                anchor = Point(x: edgeX, y: .random(in: bounds.minY...bounds.maxY, using: &random))
            } else {
                anchor = Self.randomPoint(&random, inside: bounds, slack: 0)
            }
            let pointer = Self.randomPoint(&random, inside: bounds, slack: 300)
            // Window frames partly off the display, some with edges just outside it.
            let frames = (0..<3).map { _ in
                Rect<DesktopSpace>(
                    origin: Self.randomPoint(&random, inside: bounds, slack: 8),
                    size: Size(
                        width: .random(in: 10...900, using: &random), height: .random(in: 10...700, using: &random)))
            }
            let guides = RegionPrecision.guides(within: bounds, frames: frames)
            let keys = SelectionKeys(shift: n % 7 == 0, command: n % 11 == 0)
            let aspect = SelectionAspect.allCases.randomElement(using: &random)!
            let drag = RegionPrecision.drag(
                anchor: anchor, pointer: pointer, aspect: aspect, keys: keys, guides: guides, within: bounds)
            let c = drag.corner
            let label = "case \(n): anchor \(anchor), pointer \(pointer), \(aspect), \(keys)"
            #expect(
                c.x >= bounds.minX && c.x <= bounds.maxX && c.y >= bounds.minY && c.y <= bounds.maxY,
                "\(label): corner \(c) left the display")
            if let ratio = keys.shift ? (width: 1.0, height: 1.0) : aspect.ratio {
                let w = abs(c.x - anchor.x), h = abs(c.y - anchor.y)
                #expect(abs(w * ratio.height - h * ratio.width) <= 1e-6 * max(1, w + h), "\(label): \(w) × \(h)")
            }
            for guide in drag.guides {
                #expect(
                    (guide.axis == .vertical ? c.x : c.y) == guide.position, "\(label): a guide the corner is not on")
            }
        }
    }

    @Test("Any run of nudges keeps the selection inside the display, at least the minimum, and on its ratio")
    func nudgesStayInside() {
        var random = ReviewRandom(seed: 0xA4_0002)
        let bounds = Self.display
        let minimum = 1.0
        for run in 0..<600 {
            let aspect = SelectionAspect.allCases.randomElement(using: &random)!
            let width = Double.random(in: 20...400, using: &random)
            let height = aspect.ratio.map { width * $0.height / $0.width } ?? .random(in: 20...300, using: &random)
            // Start pressed against a random corner of the display.
            let x = Bool.random(using: &random) ? bounds.minX : bounds.maxX - width
            let y = Bool.random(using: &random) ? bounds.minY : bounds.maxY - height
            var rect = Rect<DesktopSpace>(x: x, y: y, width: width, height: height)
            for step in 0..<120 {
                let direction = [NudgeDirection.left, .right, .up, .down].randomElement(using: &random)!
                let keys = SelectionKeys(shift: Bool.random(using: &random), option: Bool.random(using: &random))
                rect = RegionPrecision.nudged(
                    rect, direction, keys: keys, aspect: aspect, within: bounds, minimumSide: minimum)
                let label = "run \(run) step \(step): \(aspect) \(rect)"
                #expect(
                    rect.minX >= bounds.minX - 1e-9 && rect.minY >= bounds.minY - 1e-9
                        && rect.maxX <= bounds.maxX + 1e-9 && rect.maxY <= bounds.maxY + 1e-9,
                    "\(label) left the display")
                #expect(rect.width >= minimum && rect.height >= minimum, "\(label) below the minimum")
                if let ratio = aspect.ratio {
                    #expect(
                        abs(rect.width * ratio.height - rect.height * ratio.width) <= 1e-6 * (rect.width + rect.height),
                        "\(label) lost its ratio")
                }
            }
        }
    }

    @Test("A refit to a ratio near a corner still fits the display and holds the ratio")
    func fittedNearEdges() {
        var random = ReviewRandom(seed: 0xA4_0003)
        let bounds = Self.display
        for _ in 0..<5_000 {
            let origin = Self.randomPoint(&random, inside: bounds.insetBy(dx: 2, dy: 2), slack: 0)
            let rect = Rect<DesktopSpace>(
                origin: origin,
                size: Size(
                    width: .random(in: 2...(bounds.maxX - origin.x), using: &random),
                    height: .random(in: 2...(bounds.maxY - origin.y), using: &random)))
            for aspect in SelectionAspect.allCases {
                let fitted = RegionPrecision.fitted(rect, to: aspect, within: bounds, minimumSide: 1)
                let label = "\(rect) to \(aspect): \(fitted)"
                #expect(fitted.maxX <= bounds.maxX + 1e-9 && fitted.maxY <= bounds.maxY + 1e-9, "\(label)")
                if let ratio = aspect.ratio, fitted.width >= 1, fitted.height >= 1,
                    min(bounds.maxX - rect.minX, bounds.maxY - rect.minY) >= 2
                {
                    #expect(
                        abs(fitted.width * ratio.height - fitted.height * ratio.width)
                            <= 1e-6 * (fitted.width + fitted.height), "\(label)")
                }
            }
        }
    }
}

@Suite("Review T3/T4: framing presets keep the padding a minimum (FR-13, A-8)")
struct ReviewFramingPaddingTests {
    /// SPEC.md FR-13: a preset "grows the background to the smallest exact multiple of the ratio
    /// that holds the padded content, so padding is a minimum".
    static func paddings(canvas: Double, resize: Double, padding: Double, aspect: FramingAspect) -> (
        left: Double, right: Double, required: Double, frame: OutputFrame
    ) {
        let asset = ImageAssetInfo(
            id: AssetID(), pixelSize: PixelSize(width: Int(canvas), height: Int(canvas)), origin: .imported)
        var document = Document(asset: asset)
        document.resizeScale = resize
        document.presentation = Presentation(background: .solid(.white), padding: padding, aspect: aspect)
        let frame = document.outputFrame(exportScale: 1)
        let content = canvas * resize
        return (
            frame.contentOriginX, Double(frame.pixelSize.width) - frame.contentOriginX - content, padding * resize,
            frame
        )
    }

    @Test("Whole-pixel content: every preset keeps at least the padding on both sides")
    func wholePixelContent() {
        for aspect in FramingAspect.allCases where aspect != .free {
            for padding in [0.0, 7, 24, 60] {
                let p = Self.paddings(canvas: 120, resize: 1, padding: padding, aspect: aspect)
                #expect(p.left >= p.required && p.right >= p.required, "\(aspect), padding \(padding): \(p)")
            }
        }
    }

    @Test(
        "Fractional content (resize 0.4): a preset still keeps the padding a minimum on both sides",
        .disabled(
            "FINDING P2: Document.outputFrame rounds the padded size to nearest before taking the ratio multiple, so a 251 pt canvas at resize 0.4 with padding 25 exports 120 px wide with 9 px on the left, under the 10 px minimum (Document.swift:376-394)"
        ))
    func fractionalContent() {
        let p = Self.paddings(canvas: 251, resize: 0.4, padding: 25, aspect: .square)
        #expect(p.frame.pixelSize == PixelSize(width: 120, height: 120), "\(p.frame)")
        #expect(p.left >= p.required, "left padding \(p.left) < \(p.required)")
        #expect(p.right >= p.required, "right padding \(p.right) < \(p.required)")
    }
}
