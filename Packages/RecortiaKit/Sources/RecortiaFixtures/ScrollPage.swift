import CoreGraphics
import Foundation

/// Seeded SplitMix64: identical sequences on every run and platform.
public struct ScrollPageRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// RGBA8 (premultiplied, opaque) rows, top-down.
public struct ScrollPageBuffer: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(width: Int, height: Int, gray: UInt8) {
        self.init(width: width, height: height, pixels: Self.fill(count: width * height, gray: gray))
    }

    static func fill(count: Int, gray: UInt8) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: count * 4)
        for i in 0..<count {
            pixels[i * 4] = gray
            pixels[i * 4 + 1] = gray
            pixels[i * 4 + 2] = gray
        }
        return pixels
    }

    public func row(_ y: Int) -> ArraySlice<UInt8> { pixels[(y * width * 4)..<((y + 1) * width * 4)] }

    mutating func set(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let i = (y * width + x) * 4
        pixels[i] = r
        pixels[i + 1] = g
        pixels[i + 2] = b
    }

    mutating func set(x: Int, y: Int, gray: UInt8) { set(x: x, y: y, r: gray, g: gray, b: gray) }

    public func rows(_ range: Range<Int>) -> ArraySlice<UInt8> {
        pixels[(range.lowerBound * width * 4)..<(range.upperBound * width * 4)]
    }
}

/// A synthetic long page seen through a viewport with a fixed header and footer (SCR-01/02/04).
/// Frames are rendered as `header + page[offset ..< offset + contentHeight] + footer`, optionally
/// with an animated header spinner, a blinking caret in the content, and ±1 per-channel noise.
public struct ScrollPageFixture: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Paragraphs of pseudo-glyphs and image blocks: unique, well-textured rows.
        case text
        /// Near-uniform background with sparse thin rules.
        case lowTexture
        /// One list item repeated with an exact period.
        case repeatedRows
    }

    public struct Box: Sendable, Equatable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int

        public func contains(x px: Int, y py: Int) -> Bool {
            px >= x && px < x + width && py >= y && py < y + height
        }
    }

    public let seed: UInt64
    public let kind: Kind
    public let width: Int
    public let viewportHeight: Int
    public let headerHeight: Int
    public let footerHeight: Int
    public let animated: Bool
    public let noisy: Bool
    public let page: ScrollPageBuffer
    public let header: ScrollPageBuffer
    public let footer: ScrollPageBuffer
    /// Animated region inside the header, in frame coordinates.
    public let spinnerBox: Box?
    /// Blinking caret in page coordinates (drawn on even frame indexes).
    public let caretBox: Box?
    /// Row period of `.repeatedRows` pages.
    public let repeatPeriod: Int?

    public var contentHeight: Int { viewportHeight - headerHeight - footerHeight }
    public var pageHeight: Int { page.height }
    public var maxOffset: Int { page.height - contentHeight }

    public init(
        seed: UInt64, kind: Kind = .text, width: Int = 240, viewportHeight: Int = 320, headerHeight: Int = 40,
        footerHeight: Int = 24, pageHeight: Int = 2400, animated: Bool = true, noisy: Bool = true
    ) {
        self.seed = seed
        self.kind = kind
        self.width = width
        self.viewportHeight = viewportHeight
        self.headerHeight = headerHeight
        self.footerHeight = footerHeight
        self.animated = animated
        self.noisy = noisy
        var rng = ScrollPageRandom(seed: seed)
        switch kind {
        case .text:
            page = Self.textPage(width: width, height: pageHeight, rng: &rng)
            repeatPeriod = nil
        case .lowTexture:
            page = Self.lowTexturePage(width: width, height: pageHeight, rng: &rng)
            repeatPeriod = nil
        case .repeatedRows:
            let period = 28
            page = Self.repeatedPage(width: width, height: pageHeight, period: period, rng: &rng)
            repeatPeriod = period
        }
        header = Self.bar(width: width, height: headerHeight, gray: 222, rng: &rng)
        footer = Self.bar(width: width, height: footerHeight, gray: 206, rng: &rng)
        let spinnerSide = min(12, max(0, headerHeight - 4))
        spinnerBox =
            animated && spinnerSide > 0
            ? Box(
                x: max(0, width - spinnerSide - 6), y: (headerHeight - spinnerSide) / 2, width: spinnerSide,
                height: spinnerSide)
            : nil
        caretBox = animated && kind == .text && pageHeight > 40 ? Box(x: 1, y: 12, width: 2, height: 12) : nil
    }

    // MARK: Frames

    /// The viewport at page `offset` for frame number `index` (drives animation and noise).
    public func frameBuffer(offset: Int, index: Int, page source: ScrollPageBuffer? = nil) -> ScrollPageBuffer {
        let content = source ?? page
        precondition(offset >= 0 && offset + contentHeight <= content.height, "offset outside page")
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * viewportHeight * 4)
        pixels += header.pixels
        pixels += content.rows(offset..<(offset + contentHeight))
        pixels += footer.pixels
        var frame = ScrollPageBuffer(width: width, height: viewportHeight, pixels: pixels)
        if let spinnerBox {
            for y in spinnerBox.y..<(spinnerBox.y + spinnerBox.height) {
                for x in spinnerBox.x..<(spinnerBox.x + spinnerBox.width) {
                    frame.set(x: x, y: y, gray: UInt8(truncatingIfNeeded: index * 37 + x * 13 + y * 7))
                }
            }
        }
        if let caretBox, index % 2 == 0 {
            for py in caretBox.y..<(caretBox.y + caretBox.height) where py >= offset && py < offset + contentHeight {
                for x in caretBox.x..<(caretBox.x + caretBox.width) {
                    frame.set(x: x, y: headerHeight + py - offset, gray: 0)
                }
            }
        }
        if noisy {
            var rng = ScrollPageRandom(seed: seed &* 0x1000_0000_01B3 &+ UInt64(index) &+ 1)
            var i = 0
            while i < frame.pixels.count {
                let bits = rng.next()
                for c in 0..<3 {
                    let delta = Int((bits >> (UInt64(c) * 8)) % 3) - 1
                    frame.pixels[i + c] = UInt8(clamping: Int(frame.pixels[i + c]) + delta)
                }
                i += 4
            }
        }
        return frame
    }

    public func frame(offset: Int, index: Int, page source: ScrollPageBuffer? = nil) -> CGImage? {
        Self.image(from: frameBuffer(offset: offset, index: index, page: source))
    }

    public static func image(from buffer: ScrollPageBuffer) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: Data(buffer.pixels) as CFData)
        else { return nil }
        return CGImage(
            width: buffer.width, height: buffer.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: buffer.width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The ideal stitched output after the viewport reached `lastOffset`, with the header from
    /// frame 0: `header + page[0 ..< lastOffset + contentHeight] + footer`.
    public func expectedOutput(lastOffset: Int, page source: ScrollPageBuffer? = nil) -> ScrollPageBuffer {
        let content = source ?? page
        let pixels = header.pixels + content.rows(0..<(lastOffset + contentHeight)) + footer.pixels
        return ScrollPageBuffer(
            width: width, height: headerHeight + lastOffset + contentHeight + footerHeight, pixels: pixels)
    }

    /// True for output pixels whose value legitimately depends on the frame they came from.
    public func isAnimated(outputX x: Int, outputY y: Int) -> Bool {
        if let spinnerBox, spinnerBox.contains(x: x, y: y) { return true }
        if let caretBox, caretBox.contains(x: x, y: y - headerHeight) { return true }
        return false
    }

    // MARK: Scroll scripts

    /// Monotonic offsets from 0 to `maxOffset` with seeded steps in `steps`, stationary repeats
    /// with probability `stationaryChance`, and `trailingStationary` frames at the end.
    public func forwardOffsets(steps: ClosedRange<Int>, stationaryChance: Double = 0.1, trailingStationary: Int = 3)
        -> [Int]
    {
        var rng = ScrollPageRandom(seed: seed ^ 0x0FF5_E7)
        var offsets = [0]
        var offset = 0
        while offset < maxOffset {
            if Double(rng.next() % 1000) / 1000 < stationaryChance {
                offsets.append(offset)
                continue
            }
            offset = min(maxOffset, offset + Int.random(in: steps, using: &rng))
            offsets.append(offset)
        }
        offsets += Array(repeating: offset, count: trailingStationary)
        return offsets
    }

    /// The page with a lazily loaded block of `rows` inserted at page row `at` (content below moves down).
    public func reflowedPage(insertingRows rows: Int, at row: Int) -> ScrollPageBuffer {
        var rng = ScrollPageRandom(seed: seed ^ 0xBEEF)
        var block = ScrollPageBuffer(width: width, height: rows, gray: 250)
        Self.drawImageBlock(into: &block, top: 0, height: rows, rng: &rng)
        let pixels = page.rows(0..<row) + block.pixels + page.rows(row..<page.height)
        return ScrollPageBuffer(width: width, height: page.height + rows, pixels: Array(pixels))
    }

    // MARK: Page synthesis

    private static func textPage(width: Int, height: Int, rng: inout ScrollPageRandom) -> ScrollPageBuffer {
        var buffer = ScrollPageBuffer(width: width, height: height, gray: 250)
        var y = 8
        while y < height - 24 {
            let roll = rng.next() % 100
            if roll < 72 {
                let lines = Int.random(in: 2...6, using: &rng)
                for _ in 0..<lines where y < height - 20 {
                    drawTextLine(into: &buffer, top: y, rng: &rng)
                    y += 16
                }
            } else if roll < 88 {
                let blockHeight = min(Int.random(in: 30...80, using: &rng), height - y - 8)
                drawImageBlock(into: &buffer, top: y, height: blockHeight, rng: &rng)
                y += blockHeight
            } else {
                // A separator with a seeded dash pattern, so separators are not exact repeats.
                let x0 = Int.random(in: 4...max(4, width / 3), using: &rng)
                var bits = rng.next()
                for x in x0..<(width - 4) {
                    if x % 64 == 0 { bits = rng.next() }
                    if (bits >> UInt64(x % 64)) & 1 == 1 { buffer.set(x: x, y: y + 2, gray: 190) }
                }
                y += 5
            }
            y += Int.random(in: 6...20, using: &rng)
        }
        return buffer
    }

    /// Words of random 5x9 glyph bitmaps: text-like texture that makes every line unique.
    private static func drawTextLine(into buffer: inout ScrollPageBuffer, top: Int, rng: inout ScrollPageRandom) {
        var x = 6
        let ink = UInt8(Int.random(in: 20...70, using: &rng))
        while x < buffer.width - 12 {
            let glyphs = Int.random(in: 2...8, using: &rng)
            for _ in 0..<glyphs where x < buffer.width - 8 {
                let glyphWidth = Int.random(in: 4...6, using: &rng)
                let ascender = rng.next() % 4 == 0 ? 2 : 0
                let descender = rng.next() % 5 == 0 ? 2 : 0
                for gy in (3 - ascender)..<(12 + descender) {
                    let bits = rng.next()
                    for gx in 0..<glyphWidth where (bits >> UInt64(gx * 3)) & 7 < 3 {
                        buffer.set(x: x + gx, y: top + gy, gray: ink)
                    }
                }
                x += glyphWidth + 1
            }
            x += 5
        }
    }

    fileprivate static func drawImageBlock(
        into buffer: inout ScrollPageBuffer, top: Int, height: Int, rng: inout ScrollPageRandom
    ) {
        let a = Int.random(in: 3...9, using: &rng), b = Int.random(in: 5...13, using: &rng)
        let phase = Int.random(in: 0...255, using: &rng)
        for y in 0..<height {
            for x in 4..<(buffer.width - 4) {
                let v = (x * a + y * b + (x * y) % 17 * 5 + phase) % 256
                buffer.set(
                    x: x, y: top + y, r: UInt8(v), g: UInt8((v * 3 + y) % 256), b: UInt8((255 - v + x) % 256))
            }
        }
    }

    private static func lowTexturePage(width: Int, height: Int, rng: inout ScrollPageRandom) -> ScrollPageBuffer {
        var buffer = ScrollPageBuffer(width: width, height: height, gray: 236)
        var y = Int.random(in: 60...140, using: &rng)
        while y < height - 4 {
            let x0 = Int.random(in: 0...(width / 2), using: &rng)
            let length = Int.random(in: (width / 6)...(width / 3), using: &rng)
            for dy in 0..<Int.random(in: 1...2, using: &rng) {
                for x in x0..<min(width, x0 + length) { buffer.set(x: x, y: y + dy, gray: 214) }
            }
            y += Int.random(in: 150...220, using: &rng)
        }
        return buffer
    }

    private static func repeatedPage(width: Int, height: Int, period: Int, rng: inout ScrollPageRandom)
        -> ScrollPageBuffer
    {
        var item = ScrollPageBuffer(width: width, height: period, gray: 248)
        for y in 4..<(period - 4) {
            for x in 6..<18 { item.set(x: x, y: y, r: 70, g: 120, b: 200) }
        }
        var line = ScrollPageBuffer(width: width, height: 16, gray: 248)
        drawTextLine(into: &line, top: 0, rng: &rng)
        for y in 0..<14 {
            for x in 24..<width {
                let i = (y * width + x) * 4
                item.set(x: x, y: y + 6, r: line.pixels[i], g: line.pixels[i + 1], b: line.pixels[i + 2])
            }
        }
        for x in 0..<width { item.set(x: x, y: period - 1, gray: 225) }
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height { pixels += item.row(y % period) }
        return ScrollPageBuffer(width: width, height: height, pixels: pixels)
    }

    private static func bar(width: Int, height: Int, gray: UInt8, rng: inout ScrollPageRandom) -> ScrollPageBuffer {
        var buffer = ScrollPageBuffer(width: width, height: height, gray: gray)
        if height >= 16 {
            var line = ScrollPageBuffer(width: max(1, width / 2), height: 16, gray: gray)
            drawTextLine(into: &line, top: 0, rng: &rng)
            let top = (height - 16) / 2
            for y in 0..<16 {
                for x in 0..<line.width {
                    let i = (y * line.width + x) * 4
                    buffer.set(x: x, y: top + y, r: line.pixels[i], g: line.pixels[i + 1], b: line.pixels[i + 2])
                }
            }
        }
        for x in 0..<width { buffer.set(x: x, y: height - 1, gray: gray &- 40) }
        return buffer
    }
}
