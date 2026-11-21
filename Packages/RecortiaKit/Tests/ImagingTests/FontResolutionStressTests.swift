import CoreText
import Domain
import Foundation
import Testing

import class AppKit.NSFont
import class AppKit.NSFontDescriptor

@testable import Imaging

/// Opt-in reproduction harness for incident F-1 (docs/specs/full-source-review/f1-investigation.md).
/// Runs only with `RECORTIA_FONT_STRESS=1`, so the gate never runs it. Each variant resolves the
/// rounded, monospaced and serif system designs at sizes 8–96 with no retry and prints one
/// `F1STRESS` JSON line: attempts, nils per stage, wrong fonts, call latency, load average and the
/// thread of each failure. `RECORTIA_FONT_STRESS_VARIANTS` (comma list, default all),
/// `_ROUNDS` (default 4), `_WORKERS` (default 8, one of them on the main actor), `_SIZES`
/// (`fresh` adds a per-round fraction so no resolution can hit a font cache; default `integer`)
/// and `_POOL=1` (an autorelease pool around each resolution, so fonts are released while other
/// threads resolve: the fastest reproduction). With the `product` variant it is the regression
/// check for the shipped path; cold-process loops run the test bundle once per process.
@Suite("FontResolutionStress", .serialized)
struct FontResolutionStressTests {
    static let environment = ProcessInfo.processInfo.environment
    static let loaded = ContinuousClock.now
    static let enabled = ConditionTrait.enabled(
        if: environment["RECORTIA_FONT_STRESS"] == "1", "set RECORTIA_FONT_STRESS=1 to run the F-1 harness")

    enum Variant: String, CaseIterable, Sendable {
        /// The product path without its retry: systemFont(ofSize:), withDesign, NSFont(descriptor:size:).
        case nsFont = "nsfont"
        /// The same with a systemFont(ofSize:weight:) base.
        case nsFontWeight = "nsfont-weight"
        /// CTFontCreateWithFontDescriptor on the designed descriptor; never nil, so checked by name.
        case ctCreate = "ctcreate"
        /// CTFontDescriptorCreateMatchingFontDescriptor on the designed descriptor.
        case ctMatch = "ctmatch"
        /// NSFont.monospacedSystemFont(ofSize:weight:); monospaced design only.
        case monospacedAPI = "monospaced-api"
        /// Candidate: CTFontDescriptorCreateMatchingFontDescriptor, then CTFontCreateWithFontDescriptor
        /// on the matched descriptor; a nil match is a failure, never a fallback.
        case ctPath = "ctpath"
        /// The product path after one serial resolution of each design on the main actor.
        case nsFontWarm = "nsfont-warm"
        /// NSFont(descriptor:size:) given a Core Text-matched descriptor held strongly across the call.
        case nsFontMatched = "nsfont-matched"
        /// The shipped TextLayout.nativeFont, bounded retry included; rounded and monospaced only.
        case product = "product"
        /// Candidate: ctpath on a CTFontCreateUIFontForLanguage(.system) base instead of NSFont.systemFont.
        case ctBase = "ctbase"
    }

    enum Design: String, CaseIterable, Sendable {
        case rounded, monospaced, serif

        var system: NSFontDescriptor.SystemDesign {
            switch self {
            case .rounded: .rounded
            case .monospaced: .monospaced
            case .serif: .serif
            }
        }

        /// PostScript names this SDK resolves at idle (probe of 2026-11-21, Xcode 27.2).
        var expectedName: String {
            switch self {
            case .rounded: ".AppleSystemUIFontRounded-Regular"
            case .monospaced: ".AppleSystemUIFontMonospaced-Regular"
            case .serif: ".NewYork-Regular"
            }
        }
    }

    struct Failure: Sendable {
        let stage: String
        let design: Design
        let size: Double
        let mainThread: Bool
        let milliseconds: Double
        let time: Date
        /// Milliseconds since the process loaded this suite.
        let sinceStart: Double
        let detail: String
    }

    struct Tally: Sendable {
        var attempts = 0
        var latencies: [Double] = []
        var failures: [Failure] = []
        /// Nils of the product's font stage recovered by an immediate repeat (attempt 2 or 3).
        var recoveredByRepeat = 0
        /// Recovered only after a pause: key = pause in milliseconds.
        var recoveredAfterPause: [Int: Int] = [:]
        var unrecovered = 0

        mutating func merge(_ other: Tally) {
            attempts += other.attempts
            latencies += other.latencies
            failures += other.failures
            recoveredByRepeat += other.recoveredByRepeat
            recoveredAfterPause.merge(other.recoveredAfterPause, uniquingKeysWith: +)
            unrecovered += other.unrecovered
        }
    }

    @Test("F-1: designed system fonts resolve under load", enabled, .timeLimit(.minutes(30)))
    func stress() async throws {
        let names = Self.environment["RECORTIA_FONT_STRESS_VARIANTS"]?.split(separator: ",").map(String.init)
        let variants =
            try names.map { try $0.map { try #require(Variant(rawValue: $0), "unknown variant \($0)") } }
            ?? Variant.allCases
        let rounds = Int(Self.environment["RECORTIA_FONT_STRESS_ROUNDS"] ?? "") ?? 4
        let workers = max(1, Int(Self.environment["RECORTIA_FONT_STRESS_WORKERS"] ?? "") ?? 8)
        let fresh = Self.environment["RECORTIA_FONT_STRESS_SIZES"] == "fresh"
        let pool = Self.environment["RECORTIA_FONT_STRESS_POOL"] == "1"
        let sizes = (8...96).map(Double.init)
        let pid = ProcessInfo.processInfo.processIdentifier
        _ = Self.loaded
        for variant in variants {
            if variant == .nsFontWarm {
                await MainActor.run {
                    for design in Design.allCases {
                        let descriptor = NSFont.systemFont(ofSize: 12).fontDescriptor.withDesign(design.system)
                        _ = descriptor.flatMap { NSFont(descriptor: $0, size: 12) }
                    }
                }
            }
            let loadBefore = Self.loadAverage()
            let started = ContinuousClock.now
            let tally = await withTaskGroup(of: Tally.self) { group in
                for worker in 0..<workers {
                    @Sendable func run() -> Tally {
                        var tally = Tally()
                        for round in 0..<rounds {
                            // Each worker walks the grid in its own order, so workers overlap on
                            // different (design, size) pairs at the same moment.
                            for index in 0..<(sizes.count * Design.allCases.count) {
                                let shifted = (index * 7 + worker * 31 + round * 13) % (sizes.count * 3)
                                let design = Design.allCases[shifted % 3]
                                let base = sizes[shifted / 3]
                                let size = fresh ? base + Double(round * workers + worker + 1) / 1024 : base
                                if pool {
                                    autoreleasepool { Self.resolve(variant, design: design, size: size, into: &tally) }
                                } else {
                                    Self.resolve(variant, design: design, size: size, into: &tally)
                                }
                            }
                        }
                        return tally
                    }
                    if worker == 0 {
                        group.addTask { @MainActor in run() }
                    } else {
                        group.addTask { run() }
                    }
                }
                return await group.reduce(into: Tally()) { $0.merge($1) }
            }
            let elapsed = ContinuousClock.now - started
            print(
                Self.report(
                    variant, tally: tally, pid: pid, workers: workers, rounds: rounds, fresh: fresh, pool: pool,
                    loadBefore: loadBefore, loadAfter: Self.loadAverage(), elapsed: elapsed))
            #expect(tally.attempts > 0)
            // The regression check: the shipped path fails in this harness before the F-1 change.
            #expect(variant != .product || tally.failures.isEmpty, "product failures: \(tally.failures.count)")
        }
    }

    private static func resolve(_ variant: Variant, design: Design, size: Double, into tally: inout Tally) {
        if variant == .monospacedAPI, design != .monospaced { return }
        if variant == .product, design == .serif { return }
        tally.attempts += 1
        let mainThread = Thread.isMainThread
        let clock = ContinuousClock()
        let start = clock.now
        func fail(_ stage: String, _ detail: String = "") {
            let milliseconds = Self.milliseconds(clock.now - start)
            tally.failures.append(
                Failure(
                    stage: stage, design: design, size: size, mainThread: mainThread,
                    milliseconds: milliseconds, time: Date(),
                    sinceStart: Self.milliseconds(ContinuousClock.now - Self.loaded), detail: detail))
        }
        let base =
            variant == .nsFontWeight
            ? NSFont.systemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
        if variant == .product {
            let appearance: TextAppearance = design == .rounded ? .rounded : .monospaced
            do {
                let font = try TextLayout.nativeFont(for: appearance, size: size)
                tally.latencies.append(Self.milliseconds(clock.now - start))
                if font.fontName != design.expectedName { fail("wrongFont", font.fontName) }
            } catch {
                tally.latencies.append(Self.milliseconds(clock.now - start))
                fail("TextLayout.nativeFont", "\(error)")
            }
            return
        }
        if variant == .ctBase {
            guard let base = CTFontCreateUIFontForLanguage(.system, size, nil) else {
                fail("CTFontCreateUIFontForLanguage")
                return
            }
            guard let designed = (CTFontCopyFontDescriptor(base) as NSFontDescriptor).withDesign(design.system) else {
                fail("withDesign")
                return
            }
            guard let matched = CTFontDescriptorCreateMatchingFontDescriptor(designed as CTFontDescriptor, nil) else {
                fail("CTFontDescriptorCreateMatchingFontDescriptor")
                return
            }
            let font = CTFontCreateWithFontDescriptor(matched, size, nil)
            tally.latencies.append(Self.milliseconds(clock.now - start))
            let name = CTFontCopyPostScriptName(font) as String
            if name != design.expectedName { fail("wrongFont", name) }
            return
        }
        if variant == .monospacedAPI {
            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            tally.latencies.append(Self.milliseconds(clock.now - start))
            if font.fontName != design.expectedName { fail("wrongFont", font.fontName) }
            return
        }
        guard let descriptor = base.fontDescriptor.withDesign(design.system) else {
            fail("withDesign")
            return
        }
        switch variant {
        case .nsFont, .nsFontWeight, .nsFontWarm:
            let font = NSFont(descriptor: descriptor, size: size)
            tally.latencies.append(Self.milliseconds(clock.now - start))
            guard let font else {
                // Paired probe at the same moment: does Core Text match the same descriptor?
                let matched = CTFontDescriptorCreateMatchingFontDescriptor(descriptor as CTFontDescriptor, nil)
                let matchName = matched.flatMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
                let created = CTFontCreateWithFontDescriptor(descriptor as CTFontDescriptor, size, nil)
                fail(
                    "NSFont(descriptor:size:)",
                    "ctmatch=\(matchName ?? "nil") ctcreate=\(CTFontCopyPostScriptName(created) as String)")
                // Does the same call recover at once, after a pause, or not at all?
                for _ in 0..<2 where NSFont(descriptor: descriptor, size: size) != nil {
                    tally.recoveredByRepeat += 1
                    return
                }
                for pause in [1, 10, 100, 1000] {
                    Thread.sleep(forTimeInterval: Double(pause) / 1000)
                    if NSFont(descriptor: descriptor, size: size) != nil {
                        tally.recoveredAfterPause[pause, default: 0] += 1
                        return
                    }
                }
                tally.unrecovered += 1
                return
            }
            if font.fontName != design.expectedName { fail("wrongFont", font.fontName) }
        case .ctCreate:
            let font = CTFontCreateWithFontDescriptor(descriptor as CTFontDescriptor, size, nil)
            tally.latencies.append(Self.milliseconds(clock.now - start))
            let name = CTFontCopyPostScriptName(font) as String
            if name != design.expectedName { fail("wrongFont", name) }
        case .ctMatch:
            let matched = CTFontDescriptorCreateMatchingFontDescriptor(descriptor as CTFontDescriptor, nil)
            tally.latencies.append(Self.milliseconds(clock.now - start))
            guard let matched else {
                fail("CTFontDescriptorCreateMatchingFontDescriptor")
                return
            }
            let name = CTFontDescriptorCopyAttribute(matched, kCTFontNameAttribute) as? String ?? "nil"
            if name != design.expectedName { fail("wrongFont", name) }
        case .nsFontMatched:
            guard let matched = CTFontDescriptorCreateMatchingFontDescriptor(descriptor as CTFontDescriptor, nil)
            else {
                fail("CTFontDescriptorCreateMatchingFontDescriptor")
                return
            }
            let font = withExtendedLifetime(matched) { NSFont(descriptor: matched as NSFontDescriptor, size: size) }
            tally.latencies.append(Self.milliseconds(clock.now - start))
            guard let font else {
                fail("NSFont(descriptor:size:)", "matched descriptor")
                return
            }
            if font.fontName != design.expectedName { fail("wrongFont", font.fontName) }
        case .ctPath:
            guard let matched = CTFontDescriptorCreateMatchingFontDescriptor(descriptor as CTFontDescriptor, nil)
            else {
                tally.latencies.append(Self.milliseconds(clock.now - start))
                fail("CTFontDescriptorCreateMatchingFontDescriptor")
                return
            }
            let font = CTFontCreateWithFontDescriptor(matched, size, nil)
            tally.latencies.append(Self.milliseconds(clock.now - start))
            let name = CTFontCopyPostScriptName(font) as String
            if name != design.expectedName { fail("wrongFont", name) }
        case .monospacedAPI, .product, .ctBase:
            break
        }
    }

    private static func report(
        _ variant: Variant, tally: Tally, pid: Int32, workers: Int, rounds: Int, fresh: Bool, pool: Bool,
        loadBefore: Double, loadAfter: Double, elapsed: Duration
    ) -> String {
        let sorted = tally.latencies.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let failures = tally.failures.prefix(8).map { failure -> [String: Any] in
            [
                "stage": failure.stage, "design": failure.design.rawValue, "size": failure.size,
                "mainThread": failure.mainThread, "ms": (failure.milliseconds * 1000).rounded() / 1000,
                "time": stamp.string(from: failure.time), "detail": failure.detail,
                "sinceStartMs": failure.sinceStart.rounded(),
            ]
        }
        var stages: [String: Int] = [:]
        for failure in tally.failures { stages[failure.stage, default: 0] += 1 }
        let object: [String: Any] = [
            "variant": variant.rawValue, "pid": Int(pid), "workers": workers, "rounds": rounds,
            "sizes": (fresh ? "fresh" : "integer") + (pool ? "+pool" : ""), "attempts": tally.attempts,
            "failures": tally.failures.count, "stages": stages,
            "mainThreadFailures": tally.failures.filter(\.mainThread).count,
            "recoveredByRepeat": tally.recoveredByRepeat,
            "recoveredAfterPauseMs": Dictionary(
                uniqueKeysWithValues: tally.recoveredAfterPause.map { (String($0.key), $0.value) }),
            "unrecovered": tally.unrecovered, "loadBefore": loadBefore, "loadAfter": loadAfter,
            "elapsedMs": Self.milliseconds(elapsed).rounded(), "p50Ms": percentile(0.5),
            "p99Ms": percentile(0.99), "maxMs": sorted.last ?? 0, "examples": failures,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return "F1STRESS " + (String(data: data, encoding: .utf8) ?? "{}")
    }

    private static func loadAverage() -> Double {
        var load = [0.0, 0.0, 0.0]
        return unsafe getloadavg(&load, 3) == 3 ? load[0] : -1
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
