import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures

@testable import Imaging

/// One frame of a scripted session. `equivalentOffsets` are the viewport offsets, in the reference
/// page's rows, that correctly explain the frame; empty when none does.
struct ScrollScriptFrame {
    var offset: Int
    var equivalentOffsets: [Int]
    var page: ScrollPageBuffer?

    init(offset: Int, page: ScrollPageBuffer? = nil) {
        self.offset = offset
        self.equivalentOffsets = [offset]
        self.page = page
    }

    /// A frame of `page` after `rows` rows were inserted at reference row `insertAt`, seen at
    /// `offset` with `contentHeight` visible rows. Content wholly above the insertion keeps its
    /// offset; a viewport starting at or below it shows reference rows shifted by `rows` (any
    /// inserted rows then sit at its top edge, where the fixed-band mask may legitimately hide
    /// them). A viewport with the insertion strictly inside has no rigid explanation.
    init(reflowedOffset offset: Int, page: ScrollPageBuffer, insertAt: Int, rows: Int, contentHeight: Int) {
        self.offset = offset
        self.page = page
        if offset + contentHeight <= insertAt {
            equivalentOffsets = [offset]
        } else if offset >= insertAt {
            equivalentOffsets = [offset - rows]
        } else {
            equivalentOffsets = []
        }
    }
}

/// Outcome of feeding a script to a stitcher, judged against ground truth.
struct ScrollRunLog {
    var results: [ScrollAppendResult] = []
    /// `.accepted` whose offset differs from the true displacement: the failure SCR-02 forbids.
    var falseAccepts: [String] = []
    /// `.stationary` although the reference viewport moved.
    var movedButStationary: [Int] = []
    var pauses: [(index: Int, reason: ScrollPauseReason)] = []
    var lastAcceptedOffset: Int?
    var retainedFrameViolations: [Int] = []

    var acceptedCount: Int { results.filter { if case .accepted = $0 { true } else { false } }.count }
}

enum ScrollHarness {
    static func script(_ fixture: ScrollPageFixture, offsets: [Int]) -> [ScrollScriptFrame] {
        offsets.map { ScrollScriptFrame(offset: $0) }
    }

    static func run(
        _ fixture: ScrollPageFixture, frames: [ScrollScriptFrame], stitcher: inout ScrollStitcher,
        elapsedPerFrame: Duration = .milliseconds(100)
    ) -> ScrollRunLog {
        var log = ScrollRunLog()
        for (index, frame) in frames.enumerated() {
            guard let image = fixture.frame(offset: frame.offset, index: index, page: frame.page) else {
                log.falseAccepts.append("frame \(index) could not be rendered")
                continue
            }
            let result = stitcher.append(image, elapsed: elapsedPerFrame * index)
            log.results.append(result)
            if stitcher.retainedFullFrameCount > 2 { log.retainedFrameViolations.append(index) }
            switch result {
            case .accepted(let offset):
                if let last = log.lastAcceptedOffset {
                    if let equivalent = frame.equivalentOffsets.first(where: { $0 - last == offset }) {
                        log.lastAcceptedOffset = equivalent
                    } else {
                        log.falseAccepts.append(
                            "frame \(index) at \(frame.offset) (last accepted \(last)): accepted offset \(offset), truth \(frame.equivalentOffsets.map { $0 - last })"
                        )
                    }
                } else if offset == 0, let equivalent = frame.equivalentOffsets.first {
                    log.lastAcceptedOffset = equivalent
                } else {
                    log.falseAccepts.append("frame \(index): first frame accepted with offset \(offset)")
                }
            case .stationary:
                if let last = log.lastAcceptedOffset, !frame.equivalentOffsets.contains(last) {
                    log.movedButStationary.append(index)
                }
            case .ambiguous(let reason):
                log.pauses.append((index, reason))
            case .limitReached:
                break
            }
        }
        return log
    }

    static func rgba(_ image: CGImage) -> ScrollPageBuffer? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let copy = context.makeImage(), let data = copy.dataProvider?.data as Data? else { return nil }
        return ScrollPageBuffer(width: image.width, height: image.height, pixels: [UInt8](data))
    }

    /// Rows of `output` that differ from `expected` by more than the ±1 frame noise, ignoring
    /// pixels the fixture animates. Any missing or duplicated row misaligns everything after it.
    static func mismatchedRows(
        output: ScrollPageBuffer, expected: ScrollPageBuffer, fixture: ScrollPageFixture, noise: Int = 1
    ) -> [Int] {
        guard output.width == expected.width, output.height == expected.height else { return [-1] }
        var rows: [Int] = []
        for y in 0..<output.height {
            var bad = false
            for x in 0..<output.width where !fixture.isAnimated(outputX: x, outputY: y) {
                let i = (y * output.width + x) * 4
                for c in 0..<3 where abs(Int(output.pixels[i + c]) - Int(expected.pixels[i + c])) > noise {
                    bad = true
                }
                if bad { break }
            }
            if bad { rows.append(y) }
        }
        return rows
    }
}
