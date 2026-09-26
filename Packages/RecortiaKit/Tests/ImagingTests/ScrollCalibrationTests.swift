import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

/// Confidence calibration (SCR-02). The matcher's per-strip statistics are collected on
/// development seeds with known displacements; the baked thresholds must separate every wrong
/// strip vote from most correct ones there, and are then checked on disjoint held-out seeds.
@Suite("SCR-02: confidence calibration on development seeds, validation on held-out seeds")
struct ScrollCalibrationTests {
    static let developmentSeeds: [UInt64] = Array(1...12)
    static let heldOutSeeds: [UInt64] = Array(1001...1036)

    struct StripSample {
        var error: Double
        var margin: Double
        var correct: Bool
        var kind: ScrollPageFixture.Kind
    }

    struct StripStatistics {
        /// Textured strips (texture >= minimumTexture), the only ones allowed to vote.
        var samples: [StripSample] = []
        var strips = 0
        var featureless = 0
        var featurelessWrongExactMatches = 0
    }

    static let geometries = [(48, 140, 16, 8), (120, 260, 30, 20), (240, 320, 40, 24), (320, 420, 52, 0)]

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))]
    }

    static func collect(seeds: [UInt64]) -> StripStatistics {
        var stats = StripStatistics()
        let thresholds = ScrollMatcher.Thresholds.calibrated
        for seed in seeds {
            let kind = ScrollPageFixture.Kind.allCases[Int(seed) % ScrollPageFixture.Kind.allCases.count]
            let g = geometries[Int(seed / 3) % geometries.count]
            let fixture = ScrollPageFixture(
                seed: seed, kind: kind, width: g.0, viewportHeight: g.1, headerHeight: g.2, footerHeight: g.3,
                pageHeight: 1400)
            let offsets = fixture.forwardOffsets(steps: 1...(fixture.contentHeight * 3 / 4), stationaryChance: 0)
            let region = fixture.headerHeight..<(fixture.viewportHeight - fixture.footerHeight)
            for index in 1..<offsets.count {
                guard let previousImage = fixture.frame(offset: offsets[index - 1], index: index - 1),
                    let currentImage = fixture.frame(offset: offsets[index], index: index),
                    let previous = ScrollFrame(image: previousImage),
                    let current = ScrollFrame(image: currentImage)
                else { continue }
                let truth = offsets[index] - offsets[index - 1]
                for report in ScrollMatcher.stripReports(previous: previous, current: current, region: region) {
                    stats.strips += 1
                    guard let best = report.best else { continue }
                    guard report.texture >= thresholds.minimumTexture else {
                        stats.featureless += 1
                        if best.displacement != truth && best.error == 0 { stats.featurelessWrongExactMatches += 1 }
                        continue
                    }
                    stats.samples.append(
                        StripSample(
                            error: best.error, margin: report.margin, correct: best.displacement == truth, kind: kind))
                }
            }
        }
        return stats
    }

    /// Wrong matches as exact as the true ones (repetition) must never clear the margin, since
    /// nothing downstream could tell them apart; most correct strips on textured pages must.
    /// Wrong matches that are less exact than every true match are left to the matcher's
    /// exactness rule and consistency check, and are measured end to end on held-out seeds.
    @Test("Baked thresholds separate exact wrong strip matches from correct ones on development seeds")
    func calibrationOnDevelopmentSeeds() {
        let stats = Self.collect(seeds: Self.developmentSeeds)
        let thresholds = ScrollMatcher.Thresholds.calibrated
        let correct = stats.samples.filter(\.correct)
        let wrong = stats.samples.filter { !$0.correct }
        let maxCorrectError = correct.map(\.error).max() ?? 0
        let exactWrong = wrong.filter { $0.error <= maxCorrectError }
        let weakWrongVotes = wrong.filter {
            $0.error > maxCorrectError && $0.error <= thresholds.maximumMatchError
                && $0.margin >= thresholds.minimumMargin
        }
        let maxExactWrongMargin = exactWrong.map(\.margin).max() ?? 0
        let textMargins = correct.filter { $0.kind == .text }.map(\.margin)
        let textRecall =
            Double(textMargins.filter { $0 >= thresholds.minimumMargin }.count) / Double(max(1, textMargins.count))
        print(
            String(
                format:
                    "SCR-02 calibration (dev seeds %d...%d, 4 geometries): %d strips, %d featureless (%d matched a wrong shift exactly), %d textured: %d correct (error max %.4f), %d exact-wrong (margin max %.4f), %d weaker wrong votes",
                Self.developmentSeeds.first ?? 0, Self.developmentSeeds.last ?? 0, stats.strips, stats.featureless,
                stats.featurelessWrongExactMatches, stats.samples.count, correct.count, maxCorrectError,
                exactWrong.count,
                maxExactWrongMargin, weakWrongVotes.count))
        print(
            String(
                format:
                    "SCR-02 correct text-page margins: p1 %.4f p5 %.4f p10 %.4f median %.4f; vote recall at threshold %.3f",
                Self.percentile(textMargins, 0.01), Self.percentile(textMargins, 0.05),
                Self.percentile(textMargins, 0.10),
                Self.percentile(textMargins, 0.5), textRecall))
        print(
            String(
                format:
                    "SCR-02 baked thresholds: minimumMargin %.4f maximumMatchError %.4f minimumTexture %.4f pixelTolerance %.0f minimumAgreeingStrips %d",
                thresholds.minimumMargin, thresholds.maximumMatchError, thresholds.minimumTexture,
                Double(thresholds.pixelTolerance),
                thresholds.minimumAgreeingStrips))
        #expect(exactWrong.count > 0, "calibration set must contain repetition, or the margin bound is vacuous")
        #expect(thresholds.minimumMargin > 0 && thresholds.minimumMargin >= maxExactWrongMargin * 2)
        #expect(textRecall >= 0.9, "threshold silences too many correct strips")
        #expect(thresholds.maximumMatchError >= maxCorrectError)
        #expect(thresholds.minimumAgreeingStrips >= 3)
    }

    @Test("Held-out seeds: zero false accepts across every scenario family")
    func heldOutValidation() throws {
        var falseAccepts: [String] = []
        var movingFrames = 0, acceptedMoving = 0, pauses = 0, sessions = 0
        for seed in Self.heldOutSeeds {
            var rng = ScrollPageRandom(seed: seed)
            let width = [180, 240, 300][Int(rng.next() % 3)]
            let viewport = [260, 320, 380][Int(rng.next() % 3)]
            let header = [0, 30, 44][Int(rng.next() % 3)]
            let footer = [0, 20][Int(rng.next() % 2)]
            let family = Int(seed % 6)
            let kind: ScrollPageFixture.Kind = family == 1 ? .lowTexture : family == 2 ? .repeatedRows : .text
            let fixture = ScrollPageFixture(
                seed: seed, kind: kind, width: width, viewportHeight: viewport, headerHeight: header,
                footerHeight: footer,
                pageHeight: 1500)
            var frames = ScrollHarness.script(
                fixture, offsets: fixture.forwardOffsets(steps: 3...(fixture.contentHeight / 2), stationaryChance: 0.1))
            switch family {
            case 3:  // reverse movement in the middle
                let pivot = frames.count / 2
                let back = max(0, frames[pivot].offset - 45)
                frames.insert(ScrollScriptFrame(offset: back), at: pivot + 1)
            case 4:  // lazy-load reflow while the insertion row is visible
                let pivot = frames.count / 2
                let insertAt = min(fixture.maxOffset, frames[pivot].offset + fixture.contentHeight / 2)
                let reflowed = fixture.reflowedPage(insertingRows: 48, at: insertAt)
                let content = fixture.contentHeight
                frames = Array(frames.prefix(pivot + 1))
                for step in stride(
                    from: frames[pivot].offset, through: min(fixture.maxOffset, frames[pivot].offset + 300), by: 37)
                {
                    frames.append(
                        ScrollScriptFrame(
                            reflowedOffset: step, page: reflowed, insertAt: insertAt, rows: 48, contentHeight: content))
                }
            case 5:  // frame gap larger than the viewport
                let pivot = frames.count / 2
                let jump = min(fixture.maxOffset, frames[pivot].offset + fixture.contentHeight + 30)
                frames.insert(ScrollScriptFrame(offset: jump), at: pivot + 1)
            default:
                break
            }
            var stitcher = ScrollStitcher()
            let log = ScrollHarness.run(fixture, frames: frames, stitcher: &stitcher)
            sessions += 1
            let geometry = "w\(width) v\(viewport) h\(header) f\(footer) C\(fixture.contentHeight)"
            falseAccepts += log.falseAccepts.map { "seed \(seed) (\(kind), family \(family), \(geometry)): \($0)" }
            pauses += log.pauses.count
            // Every session's output must be row-exact against the reference page, whatever was accepted.
            if log.falseAccepts.isEmpty, let last = log.lastAcceptedOffset,
                let image = try? stitcher.assemble(), let output = ScrollHarness.rgba(image)
            {
                let bad = ScrollHarness.mismatchedRows(
                    output: output, expected: fixture.expectedOutput(lastOffset: last), fixture: fixture)
                if !bad.isEmpty {
                    falseAccepts.append(
                        "seed \(seed) (\(kind), family \(family), \(geometry)): output rows \(bad.prefix(3)) wrong")
                }
            }
            if family == 0 {
                for index in 1..<frames.count where frames[index].offset != frames[index - 1].offset {
                    movingFrames += 1
                    if log.results[index].isAccepted { acceptedMoving += 1 }
                }
            }
        }
        let recall = movingFrames == 0 ? 0 : Double(acceptedMoving) / Double(movingFrames)
        print(
            String(
                format:
                    "SCR-02 held-out (seeds %d...%d, %d sessions): false accepts %d, pauses %d, plain forward acceptance %d/%d = %.3f",
                Self.heldOutSeeds.first ?? 0, Self.heldOutSeeds.last ?? 0, sessions, falseAccepts.count, pauses,
                acceptedMoving, movingFrames, recall))
        #expect(Set(Self.heldOutSeeds).isDisjoint(with: Self.developmentSeeds))
        #expect(Set(Self.heldOutSeeds).isDisjoint(with: ScrollStitchingTests.developmentSeeds))
        #expect(falseAccepts.isEmpty, "\(falseAccepts)")
        #expect(recall >= 0.95)
    }
}
