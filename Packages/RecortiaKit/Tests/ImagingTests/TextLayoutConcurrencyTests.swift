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

    @Test("Failure diagnostics distinguish resolution stages and execution context", arguments: [false, true])
    func failureDiagnostics(isMainThread: Bool) {
        let designs: [(TextAppearance, String)] = [
            (.standard, "default"), (.rounded, "rounded"), (.monospaced, "monospaced"),
            (.outlined, "default"), (.boxed, "default"), (.roundedBoxed, "rounded"),
            (.monospacedBoxed, "monospaced"),
        ]
        for (appearance, design) in designs {
            let failures: [(TextLayoutError, String)] = [
                (.unavailableFontDesign(appearance), "withDesign"),
                (.unavailableFont(appearance), "NSFont(descriptor:size:)"),
                (.invalidGeometry, "geometry"), (.unmeasurableText, "measurement"),
            ]
            for (error, stage) in failures {
                let message = Self.failureMessage(
                    error, operation: "metrics", appearance: appearance, size: 18,
                    isMainThread: isMainThread)
                #expect(message.hasPrefix("metrics: stage=\(stage) "))
                #expect(message.contains("design=\(design) appearance=\(appearance.rawValue) "))
                #expect(message.contains("size=18.0 mainThread=\(isMainThread) "))
            }
        }
    }

    @Test(
        "Both font-resolution stages recover transient nils and stop after three identical attempts",
        arguments: ["design", "font"], [1, 2, 3, 4])
    func boundedRetries(stage: String, succeedsOn: Int) {
        let appearance = TextAppearance.roundedBoxed
        let size = 28.0
        let resolvedFont = NSFont.systemFont(ofSize: size)
        var designCalls = 0
        var fontCalls = 0
        var designInput: NSFontDescriptor?
        var fontInput: NSFontDescriptor?
        var result: NSFont?
        var failure: TextLayoutError?
        do {
            result = try TextLayout.nativeFont(
                for: appearance, size: size,
                withDesign: { descriptor, design in
                    designCalls += 1
                    #expect(design == .rounded)
                    if let designInput { #expect(descriptor === designInput) }
                    designInput = descriptor
                    return stage == "design" && designCalls < succeedsOn ? nil : descriptor
                },
                fontFromDescriptor: { descriptor, requestedSize in
                    fontCalls += 1
                    #expect(requestedSize == size)
                    #expect(descriptor === designInput)
                    if let fontInput { #expect(descriptor === fontInput) }
                    fontInput = descriptor
                    return stage == "font" && fontCalls < succeedsOn ? nil : resolvedFont
                })
        } catch {
            failure = error
        }
        let shouldSucceed = succeedsOn <= 3
        let expectedError: TextLayoutError? =
            shouldSucceed
            ? nil : (stage == "design" ? .unavailableFontDesign(appearance) : .unavailableFont(appearance))
        #expect(failure == expectedError)
        #expect(result === (shouldSucceed ? resolvedFont : nil))
        #expect(designCalls == (stage == "design" ? min(succeedsOn, 3) : 1))
        #expect(fontCalls == (stage == "font" ? min(succeedsOn, 3) : (shouldSucceed ? 1 : 0)))
    }

    private static func failureMessage(
        _ error: TextLayoutError, operation: String, appearance: TextAppearance, size: Double,
        isMainThread: Bool
    ) -> String {
        let stage: String
        switch error {
        case .unavailableFontDesign: stage = "withDesign"
        case .unavailableFont: stage = "NSFont(descriptor:size:)"
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
