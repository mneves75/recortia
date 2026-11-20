import CoreGraphics
import Darwin
import Domain
import Foundation
import RecortiaFixtures
import Synchronization
import Testing

@testable import Imaging

/// Opt-in accuracy and speed comparison of the detection methods (spike, FR-06 automatic
/// redaction). Runs only with `RECORTIA_REDACT_BENCH=1`; `RECORTIA_REDACT_BENCH_QUICK=1` limits it
/// to one size and font size for a smoke run. Prints Markdown tables; it asserts only that it ran.
enum RedactBench {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = ConditionTrait.enabled(
        if: environment["RECORTIA_REDACT_BENCH"] == "1", "set RECORTIA_REDACT_BENCH=1 to run the benchmark")
    static let quick = environment["RECORTIA_REDACT_BENCH_QUICK"] == "1"
    static let tilesEnabled = ConditionTrait.enabled(
        if: environment["RECORTIA_REDACT_BENCH_TILES"] == "1", "set RECORTIA_REDACT_BENCH_TILES=1 for the tile sweep")

    static let sizes: [(label: String, width: Int, height: Int)] = [
        ("region 1200x800", 1200, 800), ("display 1512x982", 1512, 982), ("display 2560x1440", 2560, 1440),
    ]
    static let pointSizes: [Double] = [8, 10, 12, 14, 18, 24]
    static let scales = [1, 2]
}

@Suite("SensitiveTextBenchmark", .serialized)
struct SensitiveTextBenchmarkTests {
    enum Status: String { case full, partial, missed }

    struct Outcome {
        let method: SensitiveTextMethod
        let screen: SensitiveScreen.Screen
        let size: String
        let planted: SensitiveScreen.Planted
        let status: Status
    }

    struct FalsePositive {
        let method: SensitiveTextMethod
        let category: String
        let text: String
    }

    struct Timing {
        let method: SensitiveTextMethod
        let size: String
        let scale: Int
        let seconds: Double
        let peakBytes: Int64
    }

    @Test(
        "Recall, false positives, time and memory per method", RedactBench.enabled, VisionRuntime.required,
        .timeLimit(.minutes(180)))
    func benchmark() async throws {
        var methods: [SensitiveTextMethod] = [.patterns, .dataDetector]
        if #available(macOS 26, *) { methods.append(.documents) }
        let scanner = SensitiveTextScanner()
        let english = OCRRecognitionTests.english, portuguese = OCRRecognitionTests.portuguese

        // Warm-up: model loading is not part of a capture's cost once the app has run once.
        let warm = try SensitiveScreen.render(
            widthPoints: 400, heightPoints: 200, scale: 2, pointSize: 14, theme: .light, language: .english,
            layout: .singleColumn)
        for method in methods {
            _ = try await scanner.sensitiveRegions(
                in: warm.image, pixelsPerPoint: 2, languages: [english, portuguese], method: method)
        }

        var outcomes: [Outcome] = []
        var falsePositives: [FalsePositive] = []
        var timings: [Timing] = []
        let sizes = RedactBench.quick ? [RedactBench.sizes[0]] : RedactBench.sizes
        let pointSizes = RedactBench.quick ? [12.0] : RedactBench.pointSizes
        let started = Date()
        for size in sizes {
            for scale in RedactBench.scales {
                for pointSize in pointSizes {
                    for theme in TextCorpus.Theme.allCases {
                        for language in TextCorpus.Language.allCases {
                            for layout in SensitiveScreen.Layout.allCases {
                                let screen = try SensitiveScreen.render(
                                    widthPoints: size.width, heightPoints: size.height, scale: scale,
                                    pointSize: pointSize, theme: theme, language: language, layout: layout)
                                let languages = language == .english ? [english, portuguese] : [portuguese, english]
                                for method in methods {
                                    let sampler = FootprintSampler()
                                    let sampling = Task { await sampler.run() }
                                    let clock = ContinuousClock.now
                                    let regions = try await scanner.sensitiveRegions(
                                        in: screen.image, pixelsPerPoint: Double(scale), languages: languages,
                                        method: method)
                                    let elapsed = ContinuousClock.now - clock
                                    sampling.cancel()
                                    await sampling.value
                                    timings.append(
                                        Timing(
                                            method: method, size: size.label, scale: scale,
                                            seconds: Double(elapsed.components.attoseconds) / 1e18
                                                + Double(elapsed.components.seconds),
                                            peakBytes: sampler.peakAboveBaseline))
                                    let rects = regions.map {
                                        CGRect(
                                            x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width,
                                            height: $0.rect.height)
                                    }
                                    for planted in screen.planted {
                                        let (covered, total) = Self.coverage(of: planted.rect, by: rects)
                                        let status: Status =
                                            covered >= total ? .full : covered > 0 ? .partial : .missed
                                        outcomes.append(
                                            Outcome(
                                                method: method, screen: screen, size: size.label, planted: planted,
                                                status: status))
                                    }
                                    for rect in rects
                                    where !screen.planted.contains(where: { Self.overlaps($0.rect, rect) }) {
                                        let decoy = screen.decoys.first { Self.overlaps($0.rect, rect) }
                                        falsePositives.append(
                                            FalsePositive(
                                                method: method, category: decoy?.category ?? "other text",
                                                text: decoy?.text ?? "\(rect)"))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        Self.report(
            methods: methods, outcomes: outcomes, falsePositives: falsePositives, timings: timings,
            wall: Date().timeIntervalSince(started))
        #expect(!outcomes.isEmpty)
    }

    /// Small-text recall and time by fine tile side, patterns only (`RECORTIA_REDACT_BENCH_TILES=1`).
    @Test(
        "Fine tile side vs small-text recall", RedactBench.tilesEnabled, VisionRuntime.required,
        .timeLimit(.minutes(60)))
    func tileSideSweep() async throws {
        let sides: [CGFloat] = [2048, 1448, 1024]
        let english = OCRRecognitionTests.english, portuguese = OCRRecognitionTests.portuguese
        var rows: [(side: CGFloat, size: String, pointSize: Double, full: Int, total: Int, seconds: [Double])] = []
        for size in RedactBench.sizes.prefix(2) {
            for pointSize in [8.0, 10, 12] {
                var screens: [SensitiveScreen.Screen] = []
                for scale in RedactBench.scales {
                    for theme in TextCorpus.Theme.allCases {
                        for language in TextCorpus.Language.allCases {
                            for layout in SensitiveScreen.Layout.allCases {
                                screens.append(
                                    try SensitiveScreen.render(
                                        widthPoints: size.width, heightPoints: size.height, scale: scale,
                                        pointSize: pointSize, theme: theme, language: language, layout: layout))
                            }
                        }
                    }
                }
                for side in sides {
                    let scanner = SensitiveTextScanner(fineTileSide: side)
                    var full = 0, total = 0
                    var seconds: [Double] = []
                    for screen in screens {
                        let languages =
                            screen.language == .english ? [english, portuguese] : [portuguese, english]
                        let clock = ContinuousClock.now
                        let regions = try await scanner.sensitiveRegions(
                            in: screen.image, pixelsPerPoint: Double(screen.scale), languages: languages)
                        let elapsed = ContinuousClock.now - clock
                        seconds.append(
                            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                        let rects = regions.map {
                            CGRect(x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width, height: $0.rect.height)
                        }
                        for planted in screen.planted {
                            let (covered, count) = Self.coverage(of: planted.rect, by: rects)
                            if covered >= count { full += 1 }
                            total += 1
                        }
                    }
                    rows.append((side, size.label, pointSize, full, total, seconds))
                }
            }
        }
        print("\n## Fine tile side sweep (patterns)\n")
        print("| image | font | tile side | recall | planted | p50 ms | p95 ms |")
        print("|---|---|---|---|---|---|---|")
        for row in rows {
            let sorted = row.seconds.sorted()
            func pct(_ p: Double) -> Int { Int(sorted[Int((p * Double(sorted.count - 1)).rounded())] * 1000) }
            print(
                "| \(row.size) | \(Int(row.pointSize)) pt | \(Int(row.side)) | "
                    + String(format: "%.1f%%", 100 * Double(row.full) / Double(max(row.total, 1)))
                    + " | \(row.total) | \(pct(0.5)) | \(pct(0.95)) |")
        }
        #expect(!rows.isEmpty)
    }

    // MARK: - Scoring

    /// Pixels of `rect` (integral, top-left) inside the union of `regions` (integral).
    static func coverage(of rect: CGRect, by regions: [CGRect]) -> (covered: Int, total: Int) {
        let candidates = regions.filter { $0.intersects(rect) }
        var covered = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            let spans = candidates.filter { $0.minY <= Double(y) && $0.maxY >= Double(y + 1) }
                .map { (max($0.minX, rect.minX), min($0.maxX, rect.maxX)) }
                .filter { $0.0 < $0.1 }
                .sorted { $0.0 < $1.0 }
            var end = rect.minX
            for span in spans {
                let start = max(span.0, end)
                if span.1 > start {
                    covered += Int(span.1 - start)
                    end = span.1
                }
            }
        }
        return (covered, Int(rect.width) * Int(rect.height))
    }

    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = a.intersection(b)
        return !overlap.isNull && overlap.width > 0 && overlap.height > 0
    }

    // MARK: - Report

    static func report(
        methods: [SensitiveTextMethod], outcomes: [Outcome], falsePositives: [FalsePositive], timings: [Timing],
        wall: TimeInterval
    ) {
        func percent(_ part: Int, _ whole: Int) -> String {
            whole == 0 ? "n/a" : String(format: "%.1f%%", 100 * Double(part) / Double(whole))
        }
        func recallTable(_ title: String, key: (Outcome) -> String) {
            let keys = Array(Set(outcomes.map(key))).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            print("\n### Recall by \(title)\n")
            print("| \(title) | " + methods.map { "\($0.rawValue) full / partial / n" }.joined(separator: " | ") + " |")
            print("|---|" + methods.map { _ in "---|" }.joined())
            for value in keys {
                let cells = methods.map { method -> String in
                    let group = outcomes.filter { $0.method == method && key($0) == value }
                    let full = group.filter { $0.status == .full }.count
                    let partial = group.filter { $0.status == .partial }.count
                    return "\(percent(full, group.count)) / \(partial) / \(group.count)"
                }
                print("| \(value) | " + cells.joined(separator: " | ") + " |")
            }
        }

        print("\n## SensitiveTextBenchmark results\n")
        print(
            "Wall time \(Int(wall)) s; quick mode \(RedactBench.quick); OS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
        print("\n### Overall\n")
        print("| method | planted | full (recall) | partial | missed | false-positive regions |")
        print("|---|---|---|---|---|---|")
        for method in methods {
            let group = outcomes.filter { $0.method == method }
            let full = group.filter { $0.status == .full }.count
            let partial = group.filter { $0.status == .partial }.count
            let missed = group.filter { $0.status == .missed }.count
            let fps = falsePositives.filter { $0.method == method }.count
            print(
                "| \(method.rawValue) | \(group.count) | \(full) (\(percent(full, group.count))) | \(partial) | \(missed) | \(fps) |"
            )
        }

        print("\n### Time and memory per image (ms; peak footprint above the pre-scan baseline, MB)\n")
        print("| method | image | scale | runs | p50 ms | p95 ms | max ms | peak MB |")
        print("|---|---|---|---|---|---|---|---|")
        for method in methods {
            for size in RedactBench.sizes.map(\.label) {
                for scale in RedactBench.scales {
                    let group = timings.filter { $0.method == method && $0.size == size && $0.scale == scale }
                    guard !group.isEmpty else { continue }
                    let sorted = group.map(\.seconds).sorted()
                    func pct(_ p: Double) -> Int { Int(sorted[Int((p * Double(sorted.count - 1)).rounded())] * 1000) }
                    let peak = Double(group.map(\.peakBytes).max() ?? 0) / 1_048_576
                    print(
                        "| \(method.rawValue) | \(size) | \(scale)x | \(group.count) | \(pct(0.5)) | \(pct(0.95)) | "
                            + "\(Int((sorted.last ?? 0) * 1000)) | \(String(format: "%.0f", peak)) |")
                }
            }
        }

        recallTable("font size @ scale") { "\(Int($0.screen.pointSize)) pt @\($0.screen.scale)x" }
        recallTable("scale") { "\($0.screen.scale)x" }
        recallTable("theme") { $0.screen.theme.rawValue }
        recallTable("language") { $0.screen.language.rawValue }
        recallTable("layout") { $0.screen.layout.rawValue }
        recallTable("image") { $0.size }
        recallTable("kind") { $0.planted.kind.rawValue }
        recallTable("format") { $0.planted.format }
        recallTable("image x font size") { "\($0.size) \(Int($0.screen.pointSize)) pt" }
        recallTable("theme x font size") { "\($0.screen.theme.rawValue) \(Int($0.screen.pointSize)) pt" }

        for method in methods {
            print("\n### Worst screens for \(method.rawValue) (recall, planted)\n")
            let byScreen = Dictionary(grouping: outcomes.filter { $0.method == method }, by: { $0.screen.id })
            let ranked = byScreen.map { id, group in
                (id, Double(group.filter { $0.status == .full }.count) / Double(group.count), group.count)
            }.sorted { $0.1 < $1.1 }
            for (id, recall, count) in ranked.prefix(15) {
                print("- \(id): \(String(format: "%.1f%%", recall * 100)) of \(count)")
            }
        }

        print("\n### False positives by category\n")
        let categories = Array(Set(falsePositives.map(\.category))).sorted()
        print("| category | " + methods.map(\.rawValue).joined(separator: " | ") + " |")
        print("|---|" + methods.map { _ in "---|" }.joined())
        for category in categories {
            let cells = methods.map { method in
                "\(falsePositives.filter { $0.method == method && $0.category == category }.count)"
            }
            print("| \(category) | " + cells.joined(separator: " | ") + " |")
        }

        for method in methods {
            print("\n### Samples for \(method.rawValue)\n")
            let misses = outcomes.filter { $0.method == method && $0.status != .full }
            for outcome in misses.prefix(25) {
                print(
                    "- \(outcome.status.rawValue): `\(outcome.planted.text)` (\(outcome.planted.format)) on "
                        + "\(outcome.screen.id)")
            }
            var seen = Set<String>()
            for fp in falsePositives.filter({ $0.method == method }) where seen.insert(fp.category + fp.text).inserted {
                guard seen.count <= 15 else { break }
                print("- false positive (\(fp.category)): `\(fp.text)`")
            }
        }
    }
}

/// Polls the process's physical footprint every 5 ms and keeps the peak above the first sample.
final class FootprintSampler: Sendable {
    private let state = Mutex<(baseline: Int64, peak: Int64)>((0, 0))

    var peakAboveBaseline: Int64 { state.withLock { max(0, $0.peak - $0.baseline) } }

    func run() async {
        let baseline = Self.footprint()
        state.withLock { $0 = (baseline, baseline) }
        while !Task.isCancelled {
            let now = Self.footprint()
            state.withLock { $0.peak = max($0.peak, now) }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let last = Self.footprint()
        state.withLock { $0.peak = max($0.peak, last) }
    }

    static func footprint() -> Int64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? Int64(info.ri_phys_footprint) : 0
    }
}
