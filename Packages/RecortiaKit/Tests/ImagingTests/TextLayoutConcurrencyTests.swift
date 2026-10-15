import Domain
import Foundation
import Testing

@testable import Imaging

@Suite("Text layout font resolution under concurrency (FR-05, EXP-01)")
struct TextLayoutConcurrencyTests {
    /// Hosted CI twice reported a designed system font as unavailable while other tests resolved
    /// fonts concurrently on the main actor and export threads (runs 38652457209 and
    /// 38795897584 attempt 1). Each failure records its stage so a recurrence is attributable.
    @Test("Concurrent designed-font resolution and measurement never report a missing font")
    func concurrentResolution() async {
        let sizes: [Double] = [7.5, 11, 12, 18, 24, 28, 36, 48, 96, 450]
        let appearances = TextAppearance.allCases
        @Sendable func resolve(worker: Int, step: Int) -> String? {
            let appearance = appearances[(worker + step) % appearances.count]
            let size = sizes[(worker * 7 + step) % sizes.count]
            do {
                _ = try TextLayout.nativeFont(for: appearance, size: size)
            } catch {
                return "nativeFont \(appearance) \(size): \(error)"
            }
            let text = Annotation.TextContent(
                origin: Point(x: 0, y: 0), string: "A\u{301}gua 🙂", fontSize: size, maxWidth: nil,
                appearance: appearance)
            do {
                _ = try TextLayout.metrics(for: text, style: .default)
            } catch {
                return "metrics \(appearance) \(size): \(error)"
            }
            return nil
        }
        let failures = await withTaskGroup(of: [String].self) { group in
            for worker in 0..<48 {
                if worker.isMultiple(of: 6) {
                    group.addTask { @MainActor in (0..<40).compactMap { resolve(worker: worker, step: $0) } }
                } else {
                    group.addTask { (0..<40).compactMap { resolve(worker: worker, step: $0) } }
                }
            }
            return await group.reduce(into: [String]()) { $0 += $1 }
        }
        #expect(failures.isEmpty, "\(failures.count) failures; first: \(failures.prefix(3))")
    }
}
