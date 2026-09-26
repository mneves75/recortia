import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

/// Hosted CI macOS VMs have no working Vision text-recognition runtime (both the Neural Engine and
/// the CPU path fail), so CI declares `RECORTIA_VISION_UNAVAILABLE=1`. Recognition tests are then
/// skipped, and the control below requires Vision to really fail there, so the declaration cannot
/// hide a regression on a runner where Vision works. The local gate always runs them.
enum VisionRuntime {
    static let declaredUnavailable = ProcessInfo.processInfo.environment["RECORTIA_VISION_UNAVAILABLE"] == "1"
    static let required = ConditionTrait.enabled(
        if: !declaredUnavailable, "Vision text recognition is declared unavailable on this runner")
}

@Suite("OCR-01 control: a runner that declares Vision unavailable really is")
struct VisionUnavailableControlTests {
    @Test(
        "Declared-unavailable Vision fails to recognize text",
        .enabled(if: VisionRuntime.declaredUnavailable, "only where the runner declares Vision unavailable"))
    func declaredUnavailableReallyFails() async throws {
        let sample = try #require(try TextCorpus.samples().first { $0.language == .english })
        await #expect(throws: (any Error).self, "Vision works here: remove RECORTIA_VISION_UNAVAILABLE") {
            _ = try await TextRecognizer().recognize(sample.image, languages: [OCRRecognitionTests.english])
        }
    }
}

@Suite("OCR-01: local Vision recognition corpus")
struct OCRRecognitionTests {
    let recognizer = TextRecognizer()

    static let english = Locale.Language(identifier: "en-US")
    static let portuguese = Locale.Language(identifier: "pt-BR")

    static func languages(for sample: TextCorpus.Sample) -> [Locale.Language] {
        sample.language == .english ? [english, portuguese] : [portuguese, english]
    }

    @Test("Corpus is versioned, has at least 100 samples, and is balanced EN/PT-BR")
    func corpusShape() throws {
        let samples = try TextCorpus.samples()
        #expect(samples.count >= 100)
        let english = samples.filter { $0.language == .english }.count
        #expect(english * 2 == samples.count)
        #expect(Set(samples.map(\.id)).count == samples.count)
        #expect(Set(samples.map(\.theme)) == Set(TextCorpus.Theme.allCases))
        #expect(Set(samples.map(\.category)) == Set(TextCorpus.Category.allCases))
        #expect(Set(samples.map(\.pointSize)).count >= 5)
        let text = samples.map(\.text).joined()
        for required in ["ç", "ã", "é", "ô", "á", "à", "0", "9", "%", "$", "(", ";", "{", "\""] {
            #expect(text.contains(required), "corpus lacks \(required)")
        }
    }

    @Test("CER on the clean typed-text subset is at most 1%; full-corpus CER is reported", VisionRuntime.required)
    func characterErrorRate() async throws {
        let samples = try TextCorpus.samples()
        let recognizer = self.recognizer
        let results = try await withThrowingTaskGroup(of: (Int, OCRResult).self) { group in
            var collected: [(Int, OCRResult)] = []
            var next = 0
            func enqueue() {
                guard next < samples.count else { return }
                let index = next
                let sample = samples[index]
                group.addTask {
                    (index, try await recognizer.recognize(sample.image, languages: Self.languages(for: sample)))
                }
                next += 1
            }
            for _ in 0..<4 { enqueue() }
            while let result = try await group.next() {
                collected.append(result)
                enqueue()
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var clean = CER.Tally(), full = CER.Tally()
        var byCategory: [TextCorpus.Category: CER.Tally] = [:]
        var worst: [(String, Double, String)] = []
        for (sample, result) in zip(samples, results) {
            let hypothesis = result.text(mode: .raw)
            full.add(reference: sample.text, hypothesis: hypothesis)
            byCategory[sample.category, default: CER.Tally()].add(reference: sample.text, hypothesis: hypothesis)
            if sample.isCleanTypedText { clean.add(reference: sample.text, hypothesis: hypothesis) }
            let rate = CER.rate(reference: sample.text, hypothesis: hypothesis)
            if rate > 0 { worst.append((sample.id, rate, hypothesis)) }
        }
        let revisions = Set(results.map(\.revision))
        let languageSets = Set(results.map { $0.languages.joined(separator: ",") })
        print(
            "OCR-01 corpus v\(TextCorpus.version): \(samples.count) samples, Vision RecognizeTextRequest revisions \(revisions.sorted()), languages \(languageSets.sorted()), level accurate, language correction off"
        )
        print(
            String(
                format: "OCR-01 clean subset CER %.4f%% (%d edits / %d chars, %d samples)", clean.rate * 100,
                clean.edits, clean.referenceCharacters, samples.filter(\.isCleanTypedText).count))
        print(
            String(
                format: "OCR-01 full corpus CER %.4f%% (%d edits / %d chars)", full.rate * 100, full.edits,
                full.referenceCharacters))
        for category in TextCorpus.Category.allCases {
            let tally = byCategory[category, default: CER.Tally()]
            print(String(format: "OCR-01   %@ CER %.4f%%", category.rawValue, tally.rate * 100))
        }
        for (id, rate, hypothesis) in worst.sorted(by: { $0.1 > $1.1 }).prefix(12) {
            print(
                String(
                    format: "OCR-01   %@ %.2f%% -> %@", id, rate * 100,
                    hypothesis.replacingOccurrences(of: "\n", with: " | ")))
        }
        #expect(revisions.allSatisfy { $0 > 0 })
        #expect(clean.rate <= 0.01, "clean-subset CER \(clean.rate) exceeds the 1% gate")
    }

    @Test("Line boxes land on the rendered lines in top-left source-pixel space", VisionRuntime.required)
    func boundingBoxAlignment() async throws {
        let samples = try TextCorpus.samples().filter(\.isCleanTypedText)
        for sample in samples.prefix(16) {
            let result = try await recognizer.recognize(sample.image, languages: Self.languages(for: sample))
            #expect(result.lines.count == sample.lines.count, "\(sample.id): \(result.lines.map(\.text))")
            for (line, truth) in zip(result.lines, sample.lineRects) {
                let tolerance = sample.pointSize * Double(sample.scale)
                #expect(
                    truth.contains(CGPoint(x: line.box.midX, y: line.box.midY)), "\(sample.id): \(line.box) vs \(truth)"
                )
                #expect(
                    abs(line.box.minX - truth.minX) <= tolerance, "\(sample.id) minX \(line.box.minX) vs \(truth.minX)")
                #expect(
                    abs(line.box.maxX - truth.maxX) <= tolerance, "\(sample.id) maxX \(line.box.maxX) vs \(truth.maxX)")
                #expect(line.box.height <= truth.height * 1.5 && line.box.height >= truth.height * 0.4)
            }
        }
    }

    @Test("Boxes follow text placed off-center: no vertical flip, no scale error", VisionRuntime.required)
    func boxesTrackPlacement() async throws {
        let sample = try TextCorpus.render(
            id: "placement", language: .english, category: .prose, theme: .light, pointSize: 16, scale: 2,
            lines: ["Placed near the lower right corner."])
        let canvasWidth = sample.image.width + 900, canvasHeight = sample.image.height + 700
        let dx = 850, dy = 640
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        // Core Graphics is bottom-left; placing at top-left `dy` means y = height - dy - imageHeight.
        context.draw(
            sample.image,
            in: CGRect(
                x: dx, y: canvasHeight - dy - sample.image.height, width: sample.image.width,
                height: sample.image.height))
        let canvas = try #require(context.makeImage())
        let result = try await recognizer.recognize(canvas, languages: [Self.english])
        let line = try #require(result.lines.first)
        let truth = sample.lineRects[0].offsetBy(dx: CGFloat(dx), dy: CGFloat(dy))
        #expect(truth.contains(CGPoint(x: line.box.midX, y: line.box.midY)), "\(line.box) vs \(truth)")
        #expect(line.text == "Placed near the lower right corner.")
    }

    @Test(
        "Raw, normalized, and preserve-line-breaks output differ only in whitespace; no autocorrection",
        VisionRuntime.required)
    func outputModes() async throws {
        let sample = try TextCorpus.render(
            id: "modes", language: .english, category: .prose, theme: .light, pointSize: 18, scale: 2,
            lines: ["Teh adress was recieved.", "Definately   seperate   spacing."])
        let result = try await recognizer.recognize(sample.image, languages: [Self.english])
        let raw = result.text(mode: .raw)
        let normalized = result.text(mode: .normalizedWhitespace)
        let preserved = result.text(mode: .preserveLineBreaks)
        print("OCR-01 modes raw=\(raw.debugDescription) normalized=\(normalized.debugDescription)")
        #expect(raw.split(separator: "\n").count == 2)
        #expect(preserved.split(separator: "\n").count == 2)
        #expect(!normalized.contains("\n"))
        #expect(!normalized.contains("  "))
        #expect(CER.normalized(raw) == CER.normalized(normalized))
        #expect(CER.normalized(raw) == CER.normalized(preserved))
        for misspelling in ["Teh", "adress", "recieved", "Definately", "seperate"] {
            #expect(raw.contains(misspelling), "language correction repaired \(misspelling): \(raw)")
        }
    }

    @Test("Supported languages are discovered at runtime and unavailable ones are reported")
    func languageDiscovery() async throws {
        let supported = await recognizer.supportedLanguages()
        print("OCR-01 supported recognition languages: \(supported.map(\.maximalIdentifier))")
        #expect(!supported.isEmpty)
        let availability = await recognizer.availability(of: [Self.english, Self.portuguese])
        print(
            "OCR-01 availability available=\(availability.available.map(\.maximalIdentifier)) unavailable=\(availability.unavailable.map(\.maximalIdentifier))"
        )
        #expect(availability.available.count + availability.unavailable.count == 2)
        #expect(
            availability.unavailable.isEmpty, "this host lacks \(availability.unavailable.map(\.maximalIdentifier))")

        let bogus = Locale.Language(identifier: "tlh-Latn-001")
        let image = try TextCorpus.blankImage()
        await #expect(throws: TextRecognitionError.unsupportedLanguages([bogus])) {
            _ = try await recognizer.recognize(image, languages: [Self.english, bogus])
        }
        await #expect(throws: TextRecognitionError.noLanguages) {
            _ = try await recognizer.recognize(image, languages: [])
        }
    }

    @Test("Cancellation throws CancellationError and returns no partial result")
    func cancellation() async throws {
        let lines = Array(repeating: TextCorpus.englishProse, count: 3).flatMap { $0 }
        let sample = try TextCorpus.render(
            id: "large", language: .english, category: .multilineParagraph, theme: .light, pointSize: 14, scale: 2,
            lines: lines)
        let recognizer = self.recognizer
        let task = Task { try await recognizer.recognize(sample.image, languages: [Self.english]) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("An image with no text yields an empty result", VisionRuntime.required)
    func emptyImage() async throws {
        for theme in TextCorpus.Theme.allCases {
            let result = try await recognizer.recognize(
                try TextCorpus.blankImage(theme: theme), languages: [Self.english])
            #expect(result.lines.isEmpty)
            #expect(result.isEmpty)
            #expect(result.text(mode: .raw).isEmpty)
            #expect(result.revision > 0)
            #expect(result.languages == ["en-Latn-US"])
        }
    }
}
