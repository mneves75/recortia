import Accelerate
import Domain
import Foundation
import Synchronization

/// Vertical displacement matching between two viewport frames (FR-10).
///
/// Displacement `d` means `current[y] == previous[y + d]`: positive `d` is forward (downward)
/// scrolling. Pipeline: a coarse search over row signatures proposes candidates; up to twelve
/// non-overlapping strips of the scrolling region then evaluate candidates at full resolution; a
/// textured strip votes only when its best match is good and clearly better than any distinct
/// alternative; the frame is accepted only when enough strips agree, no equally exact vote
/// disagrees, and every strip that overlaps at the chosen displacement (plus the whole overlap)
/// matches there.
package enum ScrollMatcher {
    package struct Thresholds: Sendable, Equatable {
        /// Luma difference (0-255) treated as a changed pixel. Absorbs capture noise of up to
        /// about ±8 levels per frame; far above the fixtures' ±1 noise.
        package var pixelTolerance: Float
        /// Largest fraction of changed pixels for a strip that still counts as matching.
        package var maximumMatchError: Double
        /// Smallest gap between a strip's best match and its best distinct alternative for
        /// the strip to vote.
        package var minimumMargin: Double
        package var minimumAgreeingStrips: Int
        /// Edge-pixel fraction a strip needs to carry displacement evidence. Below it (blank
        /// background) any shift matches, so the strip neither votes nor counts as repetitive.
        package var minimumTexture: Double

        /// Chosen from the development-seed calibration in ScrollCalibrationTests (seeds 1-12,
        /// four viewport geometries), which recomputes these statistics and fails if they stop
        /// holding. Measured there: every correct textured strip matched with error 0; all 396
        /// wrong matches as exact as that were repetition ties with margin 0; correct text-page
        /// margins had p1 0.027 and p5 0.042, so a 0.02 margin keeps 99% of correct votes.
        /// Held-out seeds 1001-1036 then showed no false accept.
        package static let calibrated = Thresholds(
            pixelTolerance: 16, maximumMatchError: 0.02, minimumMargin: 0.02, minimumAgreeingStrips: 3,
            minimumTexture: 0.01)
    }

    package struct Candidate: Sendable, Equatable {
        package let displacement: Int
        /// Fraction of strip pixels whose luma differs by at least the pixel tolerance.
        package let error: Double
    }

    package struct StripReport: Sendable {
        package let rows: Range<Int>
        /// Full-resolution evaluations, best first.
        package let candidates: [Candidate]
        package let texture: Double

        package var best: Candidate? { candidates.first }
        /// Best candidate that is a different hypothesis (at least two rows away from the best).
        package var runnerUp: Candidate? {
            guard let best else { return nil }
            return candidates.first { abs($0.displacement - best.displacement) >= 2 }
        }
        package var margin: Double { (runnerUp?.error ?? 1) - (best?.error ?? 1) }
    }

    package enum Decision: Sendable, Equatable {
        case stationary
        case displacement(Int)
        case pause(ScrollPauseReason)
    }

    package static let maximumStripCount = 12
    package static let maximumStripHeight = 32
    /// Enough pixels per strip that an accidental near-match is unlikely on narrow viewports.
    static let minimumStripPixels = 1024
    static let coarseCandidatesPerSearch = 4
    static let maximumTiedCandidates = 12

    package static func stripHeight(regionHeight: Int, width: Int) -> Int {
        let forPixels = (minimumStripPixels + max(1, width) - 1) / max(1, width)
        return min(maximumStripHeight, max(4, regionHeight / 20, forPixels))
    }

    /// Smallest region that can hold three strips.
    package static func minimumRegionHeight(regionHeight: Int, width: Int) -> Int {
        stripHeight(regionHeight: regionHeight, width: width) * 3
    }

    /// Non-overlapping strips of `height` rows spread evenly over `zone`, in current-frame rows.
    package static func strips(in zone: Range<Int>, height: Int) -> [Range<Int>] {
        let count = min(maximumStripCount, zone.count / max(1, height))
        guard count >= 2 else { return count == 1 ? [zone.lowerBound..<(zone.lowerBound + height)] : [] }
        let span = zone.count - height
        return (0..<count).map { i in
            let start = zone.lowerBound + span * i / (count - 1)
            return start..<(start + height)
        }
    }

    /// Strips concentrated where the frames overlap under the leading coarse candidate, so a
    /// large displacement is judged by strips that can see it; the whole region otherwise.
    package static func stripLayout(region: Range<Int>, width: Int, leading: Int?) -> [Range<Int>] {
        let height = stripHeight(regionHeight: region.count, width: width)
        if let leading {
            let zone = overlap(region: region, displacement: leading)
            if zone.count >= height * 3 { return strips(in: zone, height: height) }
        }
        return strips(in: region, height: height)
    }

    // MARK: Decision

    /// `region` must be the scrolling region between the fixed bands. Before those are known,
    /// pass `allowStationary: false`: a provisional region is only the span of rows that changed,
    /// over which "no better displacement fits" is not evidence of standing still.
    package static func decide(
        previous: ScrollFrame, current: ScrollFrame, region: Range<Int>, allowStationary: Bool = true,
        thresholds: Thresholds = .calibrated
    ) -> Decision {
        // Every helper below indexes both frames with `current`'s geometry and `region`'s rows.
        guard previous.width == current.width, previous.height == current.height, region.lowerBound >= 0,
            region.upperBound <= current.height
        else { return .pause(.lowConfidence) }
        let minimumRegion = minimumRegionHeight(regionHeight: region.count, width: current.width)
        guard region.count >= minimumRegion else { return .pause(.lowConfidence) }
        let global = coarseCandidates(previous: previous, current: current, rows: region, region: region)

        // Stationary: nothing moved beyond noise and no displacement explains the frame better.
        let still = error(
            previous: previous, current: current, rows: region, displacement: 0, tolerance: thresholds.pixelTolerance)
        if allowStationary, still <= thresholds.maximumMatchError {
            let alternatives = global.filter { $0 != 0 }.compactMap { d -> Double? in
                let rows = overlap(region: region, displacement: d)
                guard rows.count >= minimumRegion else { return nil }
                return error(
                    previous: previous, current: current, rows: rows, displacement: d,
                    tolerance: thresholds.pixelTolerance)
            }
            if alternatives.allSatisfy({ $0 >= still }),
                hasStillTexture(previous: previous, current: current, rows: region, thresholds: thresholds)
            {
                return .stationary
            }
        }

        let reports = stripReports(
            previous: previous, current: current, region: region, globalCandidates: global, thresholds: thresholds)
        var votes: [Int: (count: Int, bestError: Double, worstError: Double)] = [:]
        var repetitiveStrips = 0
        for report in reports {
            guard let best = report.best, report.texture >= thresholds.minimumTexture,
                best.error <= thresholds.maximumMatchError
            else { continue }
            if report.margin >= thresholds.minimumMargin {
                let tally = votes[best.displacement] ?? (0, best.error, best.error)
                votes[best.displacement] = (
                    tally.count + 1, min(tally.bestError, best.error), max(tally.worstError, best.error)
                )
            } else {
                repetitiveStrips += 1
            }
        }
        // Repetition is the reason only when it is broad; a lone tied strip is just weak evidence.
        let undecided: ScrollPauseReason =
            repetitiveStrips >= thresholds.minimumAgreeingStrips ? .ambiguousMatch : .lowConfidence
        let ranked = votes.sorted { ($0.value.count, -$0.value.worstError) > ($1.value.count, -$1.value.worstError) }
        guard let top = ranked.first else { return .pause(undecided) }
        let winner = top.key, tally = top.value
        // A different displacement matched at least as exactly as the winner's own strips:
        // two motions (a reflow) or a tie. A strictly weaker vote elsewhere is an accidental
        // near-match in newly exposed rows; any strip that overlaps at the winner is still
        // checked for consistency below.
        guard tally.count >= thresholds.minimumAgreeingStrips else { return .pause(undecided) }
        if ranked.dropFirst().contains(where: { $0.value.bestError <= tally.worstError }) {
            return .pause(.ambiguousMatch)
        }

        // Rigid-shift consistency: every strip that overlaps at the winner, and the whole
        // overlap, must match there. A reflow or a moving element fails this.
        for rows in reports.map(\.rows) {
            let shifted = (rows.lowerBound + winner)..<(rows.upperBound + winner)
            guard shifted.lowerBound >= region.lowerBound, shifted.upperBound <= region.upperBound else { continue }
            let e = error(
                previous: previous, current: current, rows: rows, displacement: winner,
                tolerance: thresholds.pixelTolerance)
            if e > thresholds.maximumMatchError { return .pause(.ambiguousMatch) }
        }
        let overlapRows = overlap(region: region, displacement: winner)
        let whole = error(
            previous: previous, current: current, rows: overlapRows, displacement: winner,
            tolerance: thresholds.pixelTolerance)
        guard whole <= thresholds.maximumMatchError else { return .pause(.ambiguousMatch) }

        if winner == 0 { return allowStationary ? .stationary : .pause(.lowConfidence) }
        if winner < 0 { return .pause(.reversedDirection) }
        return .displacement(winner)
    }

    /// Standing still is only claimed when textured content visibly stayed in place over at least a
    /// quarter of `rows`; blank rows stay "unchanged" under any scroll and prove nothing. Fixed
    /// bands alone rarely reach a quarter of a viewport.
    static func hasStillTexture(previous: ScrollFrame, current: ScrollFrame, rows: Range<Int>, thresholds: Thresholds)
        -> Bool
    {
        let still = rows.filter { y in
            let pair = y..<min(rows.upperBound, y + 2)
            return error(
                previous: previous, current: current, rows: y..<(y + 1), displacement: 0,
                tolerance: thresholds.pixelTolerance) == 0
                && texture(current, rows: pair, tolerance: thresholds.pixelTolerance) >= thresholds.minimumTexture
        }
        return still.count * 4 >= rows.count
    }

    /// Before the fixed bands are known, when few rows changed at the same position: whether the
    /// change is local (a caret, a spinner) rather than content that moved. Motion is evidenced
    /// by a textured run of changed rows in one frame that reappears, within the match tolerance,
    /// over changed rows of the other frame at some displacement; or, when content scrolled too
    /// far to be matched, by textured content vanishing in one place while other textured
    /// content appears elsewhere. Animation changes in place and a caret only blinks. A
    /// featureless run is no evidence, since it matches anywhere. A false "stationary" would feed
    /// end-of-page detection, so any evidence of motion pauses instead.
    package static func changedRowsAreStationary(
        previous: ScrollFrame, current: ScrollFrame, thresholds: Thresholds = .calibrated
    ) -> Bool {
        let tolerance = thresholds.pixelTolerance
        let changed = (0..<current.height).map {
            error(previous: previous, current: current, rows: $0..<($0 + 1), displacement: 0, tolerance: tolerance) > 0
        }
        var runs: [Range<Int>] = []
        var y = 0
        while y < changed.count {
            guard changed[y] else {
                y += 1
                continue
            }
            let start = y
            while y < changed.count, changed[y] { y += 1 }
            runs.append(start..<y)
        }
        // Two unchanged rows of context give a one-row element (a rule) its edges.
        func window(_ run: Range<Int>) -> Range<Int> {
            max(0, run.lowerBound - 2)..<min(current.height, run.upperBound + 2)
        }
        func isTextured(_ frame: ScrollFrame, _ run: Range<Int>) -> Bool {
            texture(frame, rows: window(run), tolerance: tolerance) >= thresholds.minimumTexture
        }
        let appeared = runs.contains { isTextured(current, $0) && !isTextured(previous, $0) }
        let vanished = runs.contains { isTextured(previous, $0) && !isTextured(current, $0) }
        if appeared && vanished { return false }
        func movedAway(from source: ScrollFrame, to target: ScrollFrame, run: Range<Int>) -> Bool {
            let window = window(run)
            guard texture(source, rows: window, tolerance: tolerance) >= thresholds.minimumTexture else { return false }
            return coarseCandidates(previous: target, current: source, rows: window, region: 0..<source.height)
                .contains { d in
                    d != 0 && window.lowerBound + d >= 0 && window.upperBound + d <= source.height
                        && ((run.lowerBound + d)..<(run.upperBound + d)).contains { changed[$0] }
                        && error(previous: target, current: source, rows: window, displacement: d, tolerance: tolerance)
                            <= thresholds.maximumMatchError
                }
        }
        if runs.contains(where: {
            movedAway(from: current, to: previous, run: $0) || movedAway(from: previous, to: current, run: $0)
        }) {
            return false
        }
        return hasStillTexture(previous: previous, current: current, rows: 0..<current.height, thresholds: thresholds)
    }

    // MARK: Strips

    package static func stripReports(
        previous: ScrollFrame, current: ScrollFrame, region: Range<Int>, globalCandidates: [Int]? = nil,
        thresholds: Thresholds = .calibrated
    ) -> [StripReport] {
        let global =
            globalCandidates ?? coarseCandidates(previous: previous, current: current, rows: region, region: region)
        return stripLayout(region: region, width: current.width, leading: global.first).map { rows in
            let valid = (region.lowerBound - rows.lowerBound)...(region.upperBound - rows.upperBound)
            var proposals = Set(coarseCandidates(previous: previous, current: current, rows: rows, region: region))
            proposals.formUnion(global)
            var displacements = Set<Int>()
            for d in proposals {
                for neighbor in (d - 1)...(d + 1) where valid.contains(neighbor) { displacements.insert(neighbor) }
            }
            func evaluate(_ d: Int) -> Candidate {
                Candidate(
                    displacement: d,
                    error: error(
                        previous: previous, current: current, rows: rows, displacement: d,
                        tolerance: thresholds.pixelTolerance))
            }
            var candidates = displacements.map(evaluate).sorted {
                ($0.error, abs($0.displacement)) < ($1.error, abs($1.displacement))
            }
            // Always measure at least one distinct alternative so the margin is never assumed.
            if let best = candidates.first,
                !candidates.contains(where: { abs($0.displacement - best.displacement) >= 2 })
            {
                for d in [best.displacement - 2, best.displacement + 2] where valid.contains(d) {
                    candidates.append(evaluate(d))
                }
                candidates.sort { ($0.error, abs($0.displacement)) < ($1.error, abs($1.displacement)) }
            }
            return StripReport(
                rows: rows, candidates: candidates,
                texture: texture(current, rows: rows, tolerance: thresholds.pixelTolerance))
        }
    }

    /// Current-frame rows of `region` whose shifted counterparts also lie inside `region`.
    package static func overlap(region: Range<Int>, displacement d: Int) -> Range<Int> {
        let lower = max(region.lowerBound, region.lowerBound - d)
        let upper = min(region.upperBound, region.upperBound - d)
        return lower < upper ? lower..<upper : region.lowerBound..<region.lowerBound
    }

    // MARK: Coarse search

    /// Local minima of the mean squared signature distance over every displacement that keeps
    /// `rows` inside `region`: the best few plus every near-tie (so repeated content surfaces as
    /// several candidates instead of one arbitrary pick).
    static func coarseCandidates(previous: ScrollFrame, current: ScrollFrame, rows: Range<Int>, region: Range<Int>)
        -> [Int]
    {
        let minimumRows = max(1, stripHeight(regionHeight: region.count, width: current.width))
        let span = region.count - minimumRows
        guard span >= 0, !rows.isEmpty else { return [] }
        var costs: [(d: Int, cost: Float)] = []
        costs.reserveCapacity(2 * span + 1)
        for d in -span...span {
            let lower = max(rows.lowerBound, region.lowerBound - d)
            let upper = min(rows.upperBound, region.upperBound - d)
            guard upper - lower >= min(minimumRows, rows.count) else { continue }
            let a = current.signatureRows(lower..<upper)
            let b = previous.signatureRows((lower + d)..<(upper + d))
            costs.append((d, vDSP.distanceSquared(a, b) / Float(a.count)))
        }
        guard !costs.isEmpty else { return [] }
        var minima: [(d: Int, cost: Float)] = []
        for i in costs.indices {
            let left = i > costs.startIndex ? costs[i - 1].cost : .infinity
            let right = i < costs.count - 1 ? costs[i + 1].cost : .infinity
            if costs[i].cost <= left && costs[i].cost <= right { minima.append(costs[i]) }
        }
        minima.sort { $0.cost < $1.cost }
        guard let best = minima.first?.cost else { return [] }
        let tieBound = best * 1.1 + 0.5
        var chosen = Array(minima.prefix(coarseCandidatesPerSearch))
        chosen += minima.dropFirst(coarseCandidatesPerSearch).filter { $0.cost <= tieBound }.prefix(
            maximumTiedCandidates)
        return chosen.map(\.d)
    }

    // MARK: Pixel measures

    /// Largest number of luma values any single comparison processes at once (256 KiB of Float).
    package static let scratchElements = 1 << 16
    /// Float temporaries a comparison chunk holds at the same time: difference, magnitude, sign.
    package static let scratchTemporaries = 3

    /// Observes the comparison chunks while bound with `$scratchProbe.withValue`, so tests can
    /// check the scratch bound on real matching paths.
    package final class ScratchProbe: Sendable {
        private let state = Mutex((largest: 0, chunks: 0))

        package init() {}

        package var largestChunk: Int { state.withLock { $0.largest } }
        package var chunkCount: Int { state.withLock { $0.chunks } }

        func record(_ elements: Int) {
            state.withLock {
                $0.largest = max($0.largest, elements)
                $0.chunks += 1
            }
        }
    }

    @TaskLocal package static var scratchProbe: ScratchProbe?

    /// Number of positions (over the shorter of `a` and `b`; callers pass equal lengths) whose
    /// values differ by at least `tolerance`, compared in chunks of at most `chunkElements` so a
    /// whole region or overlap never materializes plane-sized temporaries. `signedConstant(1)`
    /// maps |x| >= tolerance to +1 and the rest to -1; a chunk's sign sum is an integer below
    /// 2^24 and so exact in Float, which makes the count, and any fraction formed from it, equal
    /// to the unchunked computation.
    package static func changedCount(
        _ a: ArraySlice<Float>, _ b: ArraySlice<Float>, tolerance: Float, chunkElements: Int = scratchElements
    ) -> Int {
        let count = min(a.count, b.count)
        let chunk = min(max(1, chunkElements), 1 << 23)
        let probe = scratchProbe
        var changed = 0
        var offset = 0
        while offset < count {
            let n = min(chunk, count - offset)
            probe?.record(n)
            let x = a[(a.startIndex + offset)..<(a.startIndex + offset + n)]
            let y = b[(b.startIndex + offset)..<(b.startIndex + offset + n)]
            let signs = vDSP.threshold(vDSP.absolute(vDSP.subtract(x, y)), to: tolerance, with: .signedConstant(1))
            changed += (Int(vDSP.sum(signs)) + n) / 2
            offset += n
        }
        return changed
    }

    /// Fraction of pixels in current `rows` whose luma differs from previous `rows + d` by at
    /// least `tolerance`.
    package static func error(
        previous: ScrollFrame, current: ScrollFrame, rows: Range<Int>, displacement d: Int, tolerance: Float
    ) -> Double {
        guard !rows.isEmpty, rows.lowerBound + d >= 0, rows.upperBound + d <= previous.height else { return 1 }
        let a = current.lumaRows(rows)
        let b = previous.lumaRows((rows.lowerBound + d)..<(rows.upperBound + d))
        return Double(changedCount(a, b, tolerance: tolerance)) / Double(a.count)
    }

    /// Fraction of horizontally or vertically adjacent pixel pairs that differ by the tolerance.
    static func texture(_ frame: ScrollFrame, rows: Range<Int>, tolerance: Float) -> Double {
        let plane = frame.lumaRows(rows)
        guard plane.count > frame.width else { return 0 }
        let horizontal = changedCount(plane.dropFirst(), plane.dropLast(), tolerance: tolerance)
        let vertical = changedCount(plane.dropFirst(frame.width), plane.dropLast(frame.width), tolerance: tolerance)
        return (Double(horizontal) / Double(plane.count - 1) + Double(vertical) / Double(plane.count - frame.width)) / 2
    }
}
