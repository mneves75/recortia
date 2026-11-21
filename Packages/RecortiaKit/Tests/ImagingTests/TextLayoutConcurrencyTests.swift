import CoreText
import Domain
import Foundation
import Testing

import class AppKit.NSFont
import class AppKit.NSFontDescriptor

@testable import Imaging

@Suite("Text layout font resolution under concurrency (FR-05, EXP-01)")
struct TextLayoutConcurrencyTests {
    /// Hosted CI twice reported a designed system font as unavailable while other tests resolved
    /// fonts concurrently on the main actor and export threads (runs 38652457209 and
    /// 38795897584 attempt 1). Failures record the AppKit stage, design, size and calling thread.
    /// Sized for the hosted runner, where 1,920 resolutions took 66 s (run 38821022009).
    @Test("Concurrent designed-font resolution and measurement never report a missing font")
    func concurrentResolution() async {
        let sizes: [Double] = [7.5, 11, 12, 18, 24, 28, 36, 48, 96, 450]
        let appearances = TextAppearance.allCases
        @Sendable func resolve(worker: Int, step: Int) -> String? {
            let appearance = appearances[(worker + step) % appearances.count]
            let size = sizes[(worker * 7 + step) % sizes.count]
            let nativeFontOnMainThread = Thread.isMainThread
            do {
                _ = try TextLayout.nativeFont(for: appearance, size: size)
            } catch {
                return Self.failureMessage(
                    error, operation: "nativeFont", appearance: appearance, size: size,
                    isMainThread: nativeFontOnMainThread)
            }
            let text = Annotation.TextContent(
                origin: Point(x: 0, y: 0), string: "A\u{301}gua 🙂", fontSize: size, maxWidth: nil,
                appearance: appearance)
            let metricsOnMainThread = Thread.isMainThread
            do {
                _ = try TextLayout.metrics(for: text, style: .default)
            } catch {
                return Self.failureMessage(
                    error, operation: "metrics", appearance: appearance, size: size,
                    isMainThread: metricsOnMainThread)
            }
            return nil
        }
        let failures = await withTaskGroup(of: [String].self) { group in
            for worker in 0..<16 {
                if worker.isMultiple(of: 4) {
                    group.addTask { @MainActor in (0..<12).compactMap { resolve(worker: worker, step: $0) } }
                } else {
                    group.addTask { (0..<12).compactMap { resolve(worker: worker, step: $0) } }
                }
            }
            return await group.reduce(into: [String]()) { $0 += $1 }
        }
        #expect(failures.isEmpty, "\(failures.count) failures; first: \(failures.prefix(3))")
    }

    /// The F-1 reproduction: AppKit's font cache returned nil, or a system-font descriptor that
    /// `withDesign` rejects, while other threads released fonts. The autorelease pool releases each
    /// font at once. On the previous resolution path almost every run of this test failed
    /// (f1-investigation.md); a single thread never failed.
    @Test("Designed fonts resolve while other threads release fonts")
    func resolutionWhileFontsAreReleased() async {
        let failures = await withTaskGroup(of: [String].self) { group in
            for worker in 0..<16 {
                @Sendable func run() -> [String] {
                    var failures: [String] = []
                    for step in 0..<178 {
                        let appearance: TextAppearance = (worker + step).isMultiple(of: 2) ? .rounded : .monospaced
                        let size = Double(8 + (step * 7 + worker * 31) % 89)
                        autoreleasepool {
                            do {
                                _ = try TextLayout.nativeFont(for: appearance, size: size)
                            } catch {
                                failures.append("\(appearance.rawValue) \(size) main=\(Thread.isMainThread): \(error)")
                            }
                        }
                    }
                    return failures
                }
                if worker == 0 {
                    group.addTask { @MainActor in run() }
                } else {
                    group.addTask { run() }
                }
            }
            return await group.reduce(into: [String]()) { $0 += $1 }
        }
        #expect(failures.isEmpty, "\(failures.count) failures; first: \(failures.prefix(3))")
    }

    @Test(
        "Every font-resolution stage recovers transient nils and stops after three identical attempts",
        arguments: ["base", "design", "match"], [3, 4])
    func boundedRetries(stage: String, succeedsOn: Int) {
        let appearance = TextAppearance.roundedBoxed
        let size = 28.0
        let stages = ["base", "design", "match"]
        var calls: [String: Int] = [:]
        var designInput: NSFontDescriptor?
        var matchInput: NSFontDescriptor?
        func transientNil(_ name: String) -> Bool {
            calls[name, default: 0] += 1
            return stage == name && calls[name, default: 0] < succeedsOn
        }
        var result: NSFont?
        var failure: TextLayoutError?
        do {
            result = try TextLayout.nativeFont(
                for: appearance, size: size,
                systemFont: { requestedSize in
                    #expect(requestedSize == size)
                    return transientNil("base") ? nil : CTFontCreateUIFontForLanguage(.system, requestedSize, nil)
                },
                withDesign: { descriptor, design in
                    #expect(design == .rounded)
                    if let designInput { #expect(descriptor === designInput) }
                    designInput = descriptor
                    return transientNil("design") ? nil : descriptor.withDesign(design)
                },
                matchingDescriptor: { descriptor in
                    if let matchInput { #expect(descriptor === matchInput) }
                    matchInput = descriptor
                    return transientNil("match")
                        ? nil : CTFontDescriptorCreateMatchingFontDescriptor(descriptor as CTFontDescriptor, nil)
                })
        } catch {
            failure = error
        }
        let shouldSucceed = succeedsOn <= 3
        let expectedError: TextLayoutError? =
            switch (shouldSucceed, stage) {
            case (true, _): nil
            case (false, "base"): .unavailableSystemFont(appearance)
            case (false, "design"): .unavailableFontDesign(appearance)
            default: .unavailableFont(appearance)
            }
        #expect(failure == expectedError)
        #expect(result?.fontName == (shouldSucceed ? ".AppleSystemUIFontRounded-Regular" : nil))
        #expect(result?.pointSize == (shouldSucceed ? CGFloat(size) : nil))
        let failing = stages.firstIndex(of: stage) ?? 0
        for (index, name) in stages.enumerated() {
            let expected = index < failing ? 1 : index == failing ? min(succeedsOn, 3) : (shouldSucceed ? 1 : 0)
            #expect(calls[name, default: 0] == expected, "\(name) calls")
        }
    }

    /// Core Text substitutes another font for one it cannot create; that must fail, not render.
    @Test("A created font other than the matched one is reported, never returned")
    func mismatchedFontIsReported() {
        var failure: TextLayoutError?
        do {
            _ = try TextLayout.nativeFont(
                for: .monospaced, size: 18,
                systemFont: { CTFontCreateUIFontForLanguage(.system, $0, nil) },
                withDesign: { $0.withDesign($1) },
                matchingDescriptor: { _ in
                    CTFontDescriptorCreateWithNameAndSize("RecortiaNoSuchFont-F1" as CFString, 18)
                })
        } catch {
            failure = error
        }
        #expect(failure == .mismatchedFont(.monospaced))
    }

    /// Existing documents must render with the same fonts as before the F-1 change, which used
    /// `NSFont(descriptor:size:)`. A nil from that reference is F-1 itself and is skipped.
    @Test("Designed fonts equal the AppKit-resolved fonts at every size")
    func designedFontsMatchAppKit() throws {
        var compared = 0
        for appearance in TextAppearance.allCases {
            for size in [7.5, 11, 12, 18, 24, 28, 28.37, 36, 48, 96, 450] {
                let font = try TextLayout.nativeFont(for: appearance, size: size)
                let base = NSFont.systemFont(ofSize: size)
                let reference: NSFont?
                switch appearance {
                case .standard, .outlined, .boxed: reference = base
                case .rounded, .roundedBoxed:
                    reference = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) }
                case .monospaced, .monospacedBoxed:
                    reference = base.fontDescriptor.withDesign(.monospaced).flatMap {
                        NSFont(descriptor: $0, size: size)
                    }
                }
                guard let reference else { continue }
                compared += 1
                #expect(CFEqual(font as CTFont, reference as CTFont), "\(appearance) \(size): \(font) vs \(reference)")
            }
        }
        #expect(compared > 0)
    }

    private static func failureMessage(
        _ error: TextLayoutError, operation: String, appearance: TextAppearance, size: Double,
        isMainThread: Bool
    ) -> String {
        let stage: String
        switch error {
        case .unavailableSystemFont: stage = "CTFontCreateUIFontForLanguage"
        case .unavailableFontDesign: stage = "withDesign"
        case .unavailableFont: stage = "CTFontDescriptorCreateMatchingFontDescriptor"
        case .mismatchedFont: stage = "CTFontCreateWithFontDescriptor"
        case .invalidGeometry: stage = "geometry"
        case .unmeasurableText: stage = "measurement"
        }
        let design: String
        switch appearance {
        case .standard, .outlined, .boxed: design = "default"
        case .rounded, .roundedBoxed: design = "rounded"
        case .monospaced, .monospacedBoxed: design = "monospaced"
        }
        return "\(operation): stage=\(stage) design=\(design) appearance=\(appearance.rawValue) "
            + "size=\(size) mainThread=\(isMainThread) error=\(error)"
    }
}
