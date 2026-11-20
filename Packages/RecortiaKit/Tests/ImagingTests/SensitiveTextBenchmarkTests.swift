import CoreGraphics
import Darwin
import Domain
import Foundation
import RecortiaFixtures
import Synchronization
import Testing

@testable import Imaging

/// Opt-in accuracy and speed benchmark of the detector (spike, FR-06 automatic redaction). Runs only
/// with `RECORTIA_REDACT_BENCH=1`. By default it measures the pattern matcher with 2048- and 1024-px
/// fine tiles; `RECORTIA_REDACT_BENCH_ALL_METHODS=1` adds the system data detector and Vision's
/// document recognizer at 2048. `RECORTIA_REDACT_BENCH_QUICK=1` limits it to one size and font size
/// for a smoke run. Prints Markdown tables; it asserts only that it ran.
enum RedactBench {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = ConditionTrait.enabled(
        if: environment["RECORTIA_REDACT_BENCH"] == "1", "set RECORTIA_REDACT_BENCH=1 to run the benchmark")
    static let quick = environment["RECORTIA_REDACT_BENCH_QUICK"] == "1"
    static let allMethods = environment["RECORTIA_REDACT_BENCH_ALL_METHODS"] == "1"

    static let sizes: [(label: String, width: Int, height: Int)] = [
        ("region 1200x800", 1200, 800), ("display 1512x982", 1512, 982), ("display 2560x1440", 2560, 1440),
    ]
    static let pointSizes: [Double] = [8, 10, 12, 14, 18, 24]
    static let scales = [1, 2]

    /// One detector setting under test.
    struct Configuration: Hashable {
        let method: SensitiveTextMethod
        let tileSide: CGFloat
        var label: String { "\(method.rawValue) \(Int(tileSide))" }
    }

    static var configurations: [Configuration] {
        var list = [Configuration(method: .patterns, tileSide: 2048), Configuration(method: .patterns, tileSide: 1024)]
        if allMethods {
            list.append(Configuration(method: .dataDetector, tileSide: 2048))
            if #available(macOS 26, *) { list.append(Configuration(method: .documents, tileSide: 2048)) }
        }
        return list
    }
}

@Suite("SensitiveTextBenchmark", .serialized)
struct SensitiveTextBenchmarkTests {
    enum Status: String { case full, partial, missed }

    /// Metadata only: no outcome keeps a screen's bitmap alive (R14).
    struct ScreenInfo {
        let id: String
        let size: String
        let scale: Int
        let pointSize: Double
        let theme: String
        let language: String
        let layout: String
    }

    struct Outcome {
        let configuration: RedactBench.Configuration
        let screen: ScreenInfo
        let format: String
        let kind: String
        let text: String
        let status: Status
    }

    struct FalsePositive {
        let configuration: RedactBench.Configuration
        let category: String
        let text: String
    }

    struct Scan {
        let configuration: RedactBench.Configuration
        let screen: ScreenInfo
        let seconds: Double
        let peakAboveBaseline: Int64
        let peakAbsolute: Int64
        let masked: Int
        let maskedOnTargets: Int
    }

    @Test(
        "Recall, area precision, time and memory per configuration", RedactBench.enabled, VisionRuntime.required,
        .timeLimit(.minutes(240)))
    func benchmark() async throws {
        let configurations = RedactBench.configurations
        let english = OCRRecognitionTests.english, portuguese = OCRRecognitionTests.portuguese

        // Warm-up: model loading is not part of a capture's cost once the app has run once.
        do {
            let warm = try SensitiveScreen.render(
                widthPoints: 400, heightPoints: 200, scale: 2, pointSize: 14, theme: .light, language: .english,
                layout: .singleColumn)
            for configuration in configurations {
                _ = try await SensitiveTextScanner(fineTileSide: configuration.tileSide).sensitiveRegions(
                    in: warm.image, pixelsPerPoint: 2, languages: [english, portuguese], method: configuration.method)
            }
        }

        var outcomes: [Outcome] = []
        var falsePositives: [FalsePositive] = []
        var scans: [Scan] = []
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
                                let info = ScreenInfo(
                                    id: screen.id, size: size.label, scale: scale, pointSize: pointSize,
                                    theme: theme.rawValue, language: language.rawValue, layout: layout.rawValue)
                                let languages = language == .english ? [english, portuguese] : [portuguese, english]
                                for configuration in configurations {
                                    let scanner = SensitiveTextScanner(fineTileSide: configuration.tileSide)
                                    let sampler = FootprintSampler()
                                    let sampling = Task { await sampler.run() }
                                    // Stops the sampler on every exit, a thrown scan included.
                                    defer { sampling.cancel() }
                                    let clock = ContinuousClock.now
                                    let regions = try await scanner.sensitiveRegions(
                                        in: screen.image, pixelsPerPoint: Double(scale), languages: languages,
                                        method: configuration.method)
                                    let elapsed = ContinuousClock.now - clock
                                    sampling.cancel()
                                    await sampling.value
                                    let rects = regions.map {
                                        CGRect(
                                            x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width,
                                            height: $0.rect.height)
                                    }
                                    let area = Self.maskedArea(rects, on: screen.planted.map(\.rect))
                                    scans.append(
                                        Scan(
                                            configuration: configuration, screen: info,
                                            seconds: Double(elapsed.components.seconds)
                                                + Double(elapsed.components.attoseconds) / 1e18,
                                            peakAboveBaseline: sampler.peakAboveBaseline,
                                            peakAbsolute: sampler.peakAbsolute, masked: area.masked,
                                            maskedOnTargets: area.onTargets))
                                    for planted in screen.planted {
                                        let (covered, total) = Self.coverage(of: planted.rect, by: rects)
                                        let status: Status =
                                            covered >= total ? .full : covered > 0 ? .partial : .missed
                                        outcomes.append(
                                            Outcome(
                                                configuration: configuration, screen: info,
                                                format: planted.format, kind: planted.kind.rawValue,
                                                text: planted.text, status: status))
                                    }
                                    for rect in rects
                                    where !screen.planted.contains(where: { Self.overlaps($0.rect, rect) }) {
                                        let decoy = screen.decoys.first { Self.overlaps($0.rect, rect) }
                                        falsePositives.append(
                                            FalsePositive(
                                                configuration: configuration,
                                                category: decoy?.category ?? "other text",
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
            configurations: configurations, outcomes: outcomes, falsePositives: falsePositives, scans: scans,
            wall: Date().timeIntervalSince(started))
        #expect(!outcomes.isEmpty)
    }

    @Test("Area precision penalises a mask that swallows unrelated content (R10)")
    func areaPrecisionPenalisesOversizedMasks() {
        let target = CGRect(x: 10, y: 10, width: 20, height: 10)
        let tight = Self.maskedArea([target.insetBy(dx: -1, dy: -1)], on: [target])
        #expect(tight.onTargets == 200 && tight.masked == 22 * 12)
        let whole = Self.maskedArea([CGRect(x: 0, y: 0, width: 1000, height: 1000)], on: [target])
        #expect(whole.onTargets == 200 && whole.masked == 1_000_000)
        #expect(Self.coverage(of: target, by: [CGRect(x: 0, y: 0, width: 1000, height: 1000)]).covered == 200)
    }

    // MARK: - Seam experiment (review §2)

    struct SeamResult {
        let configuration: RedactBench.Configuration
        let pointSize: Double
        let placement: String
        let status: Status
        let regions: Int
    }

    @Test(
        "Seam experiment: one address inside a fine tile and across a seam", RedactBench.enabled, VisionRuntime.required
    )
    func seams() async throws {
        let seams = try await Self.seamExperiment(
            configurations: RedactBench.configurations.filter { $0.method == .patterns })
        print("\n### Seam experiment (2560x400 pt at 2x; one address inside a fine tile and across a seam)\n")
        print("| configuration | font | placement | result | regions |")
        print("|---|---|---|---|---|")
        for seam in seams {
            print(
                "| \(seam.configuration.label) | \(Int(seam.pointSize)) pt | \(seam.placement) | \(seam.status.rawValue) | "
                    + "\(seam.regions) |")
        }
        #expect(!seams.isEmpty)
    }

    /// The same long address, wholly inside the first fine tile and across the overlap of the first
    /// two (its "@" just past the first tile's edge), on a 2560 x 400 pt capture at 2x.
    static func seamExperiment(configurations: [RedactBench.Configuration]) async throws -> [SeamResult] {
        let localPart = "firstname.middlename.lastname.department.team.region"
        let address = localPart + "@example.com"
        let (widthPoints, heightPoints, scale) = (2560, 400, 2)
        let size = CGSize(width: widthPoints * scale, height: heightPoints * scale)
        var results: [SeamResult] = []
        for configuration in configurations {
            let fine = TileLayout.standard(pixelsPerPoint: Double(scale), fineTileSide: configuration.tileSide)[0]
            let columns = tileRects(for: size, layout: fine).map { ($0.minX, $0.maxX) }
            for pointSize in [12.0, 14, 18, 24] {
                func item(_ text: String, at x: CGFloat) throws -> SensitiveScreen.Screen {
                    try SensitiveScreen.renderItem(
                        text, kind: .email, widthPoints: widthPoints, heightPoints: heightPoints, scale: scale,
                        pointSize: pointSize, x: x, top: 300)
                }
                guard let ink = try item(address, at: 0).planted.first?.rect,
                    let local = try item(localPart, at: 0).planted.first?.rect, columns.count > 1
                else { continue }
                let across = (columns[0].1 + 30 - local.maxX).rounded()
                var placements: [(String, CGFloat)] = [("inside a tile", 40)]
                // Only when the whole address stays on the image and still starts well before the second tile.
                if across + ink.minX >= 40, across + ink.minX < columns[1].0 - 40 {
                    placements.append(("across a seam", across))
                }
                for (placement, x) in placements {
                    let screen = try item(address, at: x)
                    guard let planted = screen.planted.first else { continue }
                    let regions = try await SensitiveTextScanner(fineTileSide: configuration.tileSide)
                        .sensitiveRegions(
                            in: screen.image, pixelsPerPoint: Double(scale), languages: [OCRRecognitionTests.english])
                    let rects = regions.map {
                        CGRect(x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width, height: $0.rect.height)
                    }.filter { $0.intersects(planted.rect) }
                    let (covered, total) = coverage(of: planted.rect, by: rects)
                    results.append(
                        SeamResult(
                            configuration: configuration, pointSize: pointSize, placement: placement,
                            status: covered >= total ? .full : covered > 0 ? .partial : .missed,
                            regions: rects.count))
                }
            }
        }
        return results
    }

    // MARK: - Scoring

    /// Pixels of `rect` (integral, top-left) inside the union of `regions` (integral).
    static func coverage(of rect: CGRect, by regions: [CGRect]) -> (covered: Int, total: Int) {
        let candidates = regions.filter { $0.intersects(rect) }
        var covered = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            covered += length(of: intersect(spans(of: candidates, row: y), [(rect.minX, rect.maxX)]))
        }
        return (covered, Int(rect.width) * Int(rect.height))
    }

    /// Masked pixels (the union of `masks`), and how many of them lie on a planted item's ink box.
    /// Their ratio is the area precision: a mask that swallows unrelated content scores low even
    /// though it touches a target (R10).
    static func maskedArea(_ masks: [CGRect], on targets: [CGRect]) -> (masked: Int, onTargets: Int) {
        guard let top = masks.map(\.minY).min(), let bottom = masks.map(\.maxY).max() else { return (0, 0) }
        var masked = 0, onTargets = 0
        for y in Int(top)..<Int(bottom) {
            let row = spans(of: masks, row: y)
            guard !row.isEmpty else { continue }
            masked += length(of: row)
            onTargets += length(of: intersect(row, spans(of: targets, row: y)))
        }
        return (masked, onTargets)
    }

    /// Disjoint, sorted horizontal spans of the rectangles that cover pixel row `y`.
    private static func spans(of rects: [CGRect], row y: Int) -> [(CGFloat, CGFloat)] {
        let sorted = rects.filter { $0.minY <= Double(y) && $0.maxY >= Double(y + 1) }.map { ($0.minX, $0.maxX) }
            .sorted { $0.0 < $1.0 }
        var merged: [(CGFloat, CGFloat)] = []
        for span in sorted {
            if let last = merged.last, span.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, span.1)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private static func intersect(_ a: [(CGFloat, CGFloat)], _ b: [(CGFloat, CGFloat)]) -> [(CGFloat, CGFloat)] {
        a.flatMap { x in b.compactMap { y in max(x.0, y.0) < min(x.1, y.1) ? (max(x.0, y.0), min(x.1, y.1)) : nil } }
    }

    private static func length(of spans: [(CGFloat, CGFloat)]) -> Int {
        spans.reduce(0) { $0 + Int($1.1 - $1.0) }
    }

    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = a.intersection(b)
        return !overlap.isNull && overlap.width > 0 && overlap.height > 0
    }

    // MARK: - Report

    static func report(
        configurations: [RedactBench.Configuration], outcomes: [Outcome], falsePositives: [FalsePositive],
        scans: [Scan], wall: TimeInterval
    ) {
        func percent(_ part: Int, _ whole: Int) -> String {
            whole == 0 ? "n/a" : String(format: "%.1f%%", 100 * Double(part) / Double(whole))
        }
        func megabytes(_ bytes: Int64) -> String { String(format: "%.0f", Double(bytes) / 1_048_576) }
        func recallTable(_ title: String, key: (Outcome) -> String) {
            let keys = Array(Set(outcomes.map(key))).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            print("\n### Recall by \(title)\n")
            print(
                "| \(title) | " + configurations.map { "\($0.label) full / partial / n" }.joined(separator: " | ")
                    + " |")
            print("|---|" + configurations.map { _ in "---|" }.joined())
            for value in keys {
                let cells = configurations.map { configuration -> String in
                    let group = outcomes.filter { $0.configuration == configuration && key($0) == value }
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
        print(
            "| configuration | planted | full (recall) | partial | missed | false-positive regions | area precision |")
        print("|---|---|---|---|---|---|---|")
        for configuration in configurations {
            let group = outcomes.filter { $0.configuration == configuration }
            let full = group.filter { $0.status == .full }.count
            let partial = group.filter { $0.status == .partial }.count
            let missed = group.filter { $0.status == .missed }.count
            let fps = falsePositives.filter { $0.configuration == configuration }.count
            let area = scans.filter { $0.configuration == configuration }
            print(
                "| \(configuration.label) | \(group.count) | \(full) (\(percent(full, group.count))) | \(partial) | "
                    + "\(missed) | \(fps) | \(percent(area.map(\.maskedOnTargets).reduce(0, +), area.map(\.masked).reduce(0, +))) |"
            )
        }

        print("\n### Time and memory per image (ms; peak footprint MB above the pre-scan baseline / absolute)\n")
        print("| configuration | image | scale | runs | p50 ms | p95 ms | max ms | peak MB | absolute MB |")
        print("|---|---|---|---|---|---|---|---|---|")
        for configuration in configurations {
            for size in RedactBench.sizes.map(\.label) {
                for scale in RedactBench.scales {
                    let group = scans.filter {
                        $0.configuration == configuration && $0.screen.size == size && $0.screen.scale == scale
                    }
                    guard !group.isEmpty else { continue }
                    let sorted = group.map(\.seconds).sorted()
                    func pct(_ p: Double) -> Int { Int(sorted[Int((p * Double(sorted.count - 1)).rounded())] * 1000) }
                    print(
                        "| \(configuration.label) | \(size) | \(scale)x | \(group.count) | \(pct(0.5)) | \(pct(0.95)) | "
                            + "\(Int((sorted.last ?? 0) * 1000)) | \(megabytes(group.map(\.peakAboveBaseline).max() ?? 0)) | "
                            + "\(megabytes(group.map(\.peakAbsolute).max() ?? 0)) |")
                }
            }
        }

        print("\n### Recall and area precision by image size\n")
        print("| configuration | image | full (recall) | planted | area precision |")
        print("|---|---|---|---|---|")
        for configuration in configurations {
            for size in RedactBench.sizes.map(\.label) {
                let group = outcomes.filter { $0.configuration == configuration && $0.screen.size == size }
                guard !group.isEmpty else { continue }
                let area = scans.filter { $0.configuration == configuration && $0.screen.size == size }
                print(
                    "| \(configuration.label) | \(size) | \(percent(group.filter { $0.status == .full }.count, group.count)) | "
                        + "\(group.count) | \(percent(area.map(\.maskedOnTargets).reduce(0, +), area.map(\.masked).reduce(0, +))) |"
                )
            }
        }

        recallTable("font size @ scale") { "\(Int($0.screen.pointSize)) pt @\($0.screen.scale)x" }
        recallTable("theme") { $0.screen.theme }
        recallTable("language") { $0.screen.language }
        recallTable("layout") { $0.screen.layout }
        recallTable("kind") { $0.kind }
        recallTable("format") { $0.format }
        recallTable("image x font size") { "\($0.screen.size) \(Int($0.screen.pointSize)) pt" }

        for configuration in configurations {
            print("\n### Worst screens for \(configuration.label) (recall, planted)\n")
            let byScreen = Dictionary(
                grouping: outcomes.filter { $0.configuration == configuration }, by: { $0.screen.id })
            let ranked = byScreen.map { id, group in
                (id, Double(group.filter { $0.status == .full }.count) / Double(group.count), group.count)
            }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            for (id, recall, count) in ranked.prefix(10) {
                print("- \(id): \(String(format: "%.1f%%", recall * 100)) of \(count)")
            }
        }

        print("\n### False positives by category\n")
        let categories = Array(Set(falsePositives.map(\.category))).sorted()
        print("| category | " + configurations.map(\.label).joined(separator: " | ") + " |")
        print("|---|" + configurations.map { _ in "---|" }.joined())
        for category in categories {
            let cells = configurations.map { configuration in
                "\(falsePositives.filter { $0.configuration == configuration && $0.category == category }.count)"
            }
            print("| \(category) | " + cells.joined(separator: " | ") + " |")
        }

        for configuration in configurations {
            print("\n### Samples for \(configuration.label)\n")
            let misses = outcomes.filter { $0.configuration == configuration && $0.status != .full }
            for outcome in misses.prefix(20) {
                print("- \(outcome.status.rawValue): `\(outcome.text)` (\(outcome.format)) on \(outcome.screen.id)")
            }
            var seen = Set<String>()
            for fp in falsePositives.filter({ $0.configuration == configuration })
            where seen.insert(fp.category + fp.text).inserted {
                guard seen.count <= 10 else { break }
                print("- false positive (\(fp.category)): `\(fp.text)`")
            }
        }
    }
}

/// Polls the process's physical footprint every 5 ms. The baseline is taken synchronously when the
/// sampler is made, before the scan starts, so the peak above it is the scan's own growth (R14).
final class FootprintSampler: Sendable {
    private let state: Mutex<(baseline: Int64, peak: Int64)>

    init() {
        let baseline = Self.footprint()
        state = Mutex((baseline, baseline))
    }

    var peakAboveBaseline: Int64 { state.withLock { max(0, $0.peak - $0.baseline) } }
    var peakAbsolute: Int64 { state.withLock { $0.peak } }

    func run() async {
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
