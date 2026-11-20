// Detection of e-mail addresses and phone numbers in captures (FR-06 automatic redaction, spike).
//
// The patterns, the tiled sweep, fragment joining and region merging are adapted from Fosco by
// Gabriel Buzzi, https://github.com/gabrielbuzziv/fosco at commit
// cf6ca8d4f176a5c6628a6ccfdb2c2db0abaa5ba8 (Sources/FoscoCore/TextDetector.swift, TextScanner.swift,
// TileLayout.swift, FragmentRuns.swift), used under the MIT License:
//
// MIT License
//
// Copyright (c) 2026 Gabriel Buzzi Venturi
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
// associated documentation files (the "Software"), to deal in the Software without restriction,
// including without limitation the rights to use, copy, modify, merge, publish, distribute,
// sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or
// substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
// NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
// OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// Changes from the original: patterns compile once behind a typed error instead of `try!`; the sweep
// is structured concurrency over Recortia's `TextRecognizer` and surfaces recognition failure instead
// of logging it; boxes are outset to whole pixels; two alternative matchers exist for comparison.

import CoreGraphics
import Domain
import Foundation
import Vision

public enum SensitiveTextKind: String, Sendable, CaseIterable, Hashable {
    case email
    case phone
}

public struct SensitiveTextMatch: Sendable, Equatable {
    public let kind: SensitiveTextKind
    public let range: Range<String.Index>
}

public enum SensitiveTextError: Error, Equatable, Sendable {
    /// A built-in pattern failed to compile; carries the pattern's name.
    case patternInvalid(String)
    case dataDetectorUnavailable
    /// A tile of the capture could not be cropped or resampled.
    case tileUnavailable
    /// The document recognizer failed on both its default and CPU compute paths.
    case documentRecognitionFailed
    /// The requested method needs a newer macOS than the running one.
    case methodUnavailable
}

// MARK: - Pattern matcher (variant A)

/// Finds e-mail addresses and phone numbers in one line of text. Built for OCR output, so it
/// tolerates the damage Vision typically does (a stray space after a dot, a missing separator).
public struct SensitiveTextMatcher: Sendable {
    enum Refinement: Sendable {
        case none
        case rejectGitRemote
        case acceptDamagedDomain
        case trimInternationalNumber
    }

    struct Pattern: Sendable {
        let name: String
        let kind: SensitiveTextKind
        let source: String
        let refinement: Refinement
    }

    private struct Compiled: Sendable {
        let pattern: Pattern
        let regex: NSRegularExpression
    }

    private let compiled: [Compiled]
    private let digitRuns: Compiled

    /// Compiled once per process; every caller shares it.
    public static let shared = Result { () throws(SensitiveTextError) in try SensitiveTextMatcher() }

    public init() throws(SensitiveTextError) {
        var compiled: [Compiled] = []
        for pattern in Self.patterns { compiled.append(try Self.compile(pattern)) }
        self.compiled = compiled
        digitRuns = try Self.compile(Pattern(name: "digit-runs", kind: .phone, source: #"\d+"#, refinement: .none))
    }

    private static func compile(_ pattern: Pattern) throws(SensitiveTextError) -> Compiled {
        do {
            return Compiled(
                pattern: pattern, regex: try NSRegularExpression(pattern: pattern.source, options: [.caseInsensitive]))
        } catch {
            throw .patternInvalid(pattern.name)
        }
    }

    public func matches(
        in text: String, kinds: Set<SensitiveTextKind> = Set(SensitiveTextKind.allCases)
    ) -> [SensitiveTextMatch] {
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        var found: [(kind: SensitiveTextKind, range: NSRange)] = []
        for detector in compiled where kinds.contains(detector.pattern.kind) {
            for result in detector.regex.matches(in: text, range: whole) {
                guard let range = refine(detector.pattern.refinement, source, result.range) else { continue }
                found.append((detector.pattern.kind, range))
            }
        }
        return Self.mergeOverlapping(found).compactMap { item in
            Range(item.range, in: text).map { SensitiveTextMatch(kind: item.kind, range: $0) }
        }
    }

    private func refine(_ refinement: Refinement, _ source: NSString, _ range: NSRange) -> NSRange? {
        switch refinement {
        case .none: return range
        case .rejectGitRemote: return Self.rejectGitRemote(source, range)
        case .acceptDamagedDomain: return Self.acceptDamagedDomain(source, range)
        case .trimInternationalNumber: return trimInternationalNumber(source, range)
        }
    }

    // MARK: Patterns

    private static let localChars = #"[a-z0-9._%+\-…]"#
    /// Suffixes accepted after an OCR-inserted space ("gmail. com"). Lowercase only, and no suffix
    /// that doubles as a word ("me", "us"), so "x@exemplo.com. Me liga" keeps its next sentence.
    private static let spacedSuffix = #"(?-i:com|net|org|br|io|dev|app|edu|gov)(?![a-z0-9\-])"#
    private static let fullDomain =
        #"(?:[a-z0-9\-]+(?:\.\s(?=\#(spacedSuffix))|\.))+[a-z]{2,24}(?![a-z0-9\-])"#
    /// Domain cut off by the UI: "maria@gm…".
    private static let truncatedDomain = #"[a-z0-9.\-]*(?:…|\.{3})"#
    private static let mailProviders = "gmail|hotmail|outlook|yahoo|icloud|live|uol|bol|terra|proton(?:mail)?"
    /// One separator between digit groups (space, dot, any hyphen or dash).
    private static let sep = #"[\s.\-‐-—]"#
    /// Do not start inside a longer number, an id (#123…) or a decimal.
    private static let leftEdge = #"(?<![\d#.,+\-])"#
    /// Do not stop inside a longer number or a decimal.
    private static let rightEdge = #"(?!\d)(?![.,\-]\d)"#
    /// Brazilian area codes (DDD) in use.
    private static let areaCode = "(?:1[1-9]|2[12478]|3[1-578]|4[1-9]|5[1345]|6[1-9]|7[134579]|8[1-9]|9[1-9])"

    static let patterns: [Pattern] = [
        // name@domain.tld, with an optional OCR space after a dot in the local part.
        Pattern(
            name: "email", kind: .email,
            source: #"(?:\#(localChars)+\.\s)?\#(localChars)+@(?:\#(fullDomain)|\#(truncatedDomain))"#,
            refinement: .rejectGitRemote),
        // Top-level domain damaged by OCR: "x@startup-io", "x@startup.1o", "x@gmail,corn".
        Pattern(
            name: "email-damaged-domain", kind: .email,
            source: #"\#(localChars)+@[a-z][a-z0-9.\-]*[.,\-][a-z0-9]{2,5}(?![a-z0-9\-])"#,
            refinement: .acceptDamagedDomain),
        // "@" misread as a letter in front of a well-known mail provider ("anadgmail.com").
        Pattern(
            name: "email-lost-at", kind: .email,
            source: #"[a-z0-9._%+\-]{2,}(?<![.@])(?:\#(mailProviders))\.(?:com|me)(?:\.br)?(?![a-z0-9\-])"#,
            refinement: .none),
        // Brazil: optional +55, area code, then mobile (9 + 8 digits) or landline (8 digits).
        Pattern(
            name: "phone-br", kind: .phone,
            source:
                #"\#(leftEdge)(?:\+?55\#(sep)?)?\(?0?\#(areaCode)\)?\#(sep)?(?:9\#(sep)?\d{4}|[2-8]\d{3})\#(sep)?\d{4}\#(rightEdge)"#,
            refinement: .none),
        // Brazilian mobile without area code: 90765-4321.
        Pattern(
            name: "phone-br-local", kind: .phone, source: #"\#(leftEdge)9\#(sep)?\d{4}-\d{4}\#(rightEdge)"#,
            refinement: .none),
        // North America: (415) 555-0132, 415-555-0199, +1 415 555 0199.
        Pattern(
            name: "phone-nanp", kind: .phone,
            source:
                #"\#(leftEdge)(?:\+?1\#(sep)?)?(?:\([2-9]\d{2}\)\s?|[2-9]\d{2}\#(sep))\d{3}\#(sep)\d{4}\#(rightEdge)"#,
            refinement: .none),
        // Any other number written with a country code: +351 912 345 678.
        Pattern(
            name: "phone-international", kind: .phone, source: #"(?<![\d#])\+\d{1,3}(?:\#(sep)?\(?\d{1,12}\)?){1,8}"#,
            refinement: .trimInternationalNumber),
    ]

    /// "git@github.com:org/repo.git" is an SSH remote, not an address.
    private static func rejectGitRemote(_ source: NSString, _ range: NSRange) -> NSRange? {
        source.substring(with: range).lowercased().hasPrefix("git@") ? nil : range
    }

    /// Accepts "name@domain<sep><suffix>" when the suffix is a known one once the usual OCR
    /// confusions (0/o, 1/i, rn/m) are undone. A hyphen stands in for the dot only before suffixes
    /// that are rare as the last word of a host name, so "deploy@api-dev" is left alone.
    private static func acceptDamagedDomain(_ source: NSString, _ range: NSRange) -> NSRange? {
        let text = source.substring(with: range).lowercased()
        guard rejectGitRemote(source, range) != nil, let separator = text.lastIndex(where: { ".,-".contains($0) })
        else { return nil }
        let suffix = text[text.index(after: separator)...]
            .replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: "1", with: "i")
            .replacingOccurrences(of: "rn", with: "m")
        let known = text[separator] == "-" ? hyphenatedSuffixes : domainSuffixes
        return known.contains(suffix) ? range : nil
    }

    private static let hyphenatedSuffixes: Set<String> = ["com", "br", "net", "org", "io"]
    private static let domainSuffixes: Set<String> = hyphenatedSuffixes.union([
        "dev", "app", "co", "me", "ai", "edu", "gov", "info", "tech", "biz", "xyz", "site", "store", "cloud",
        "online", "adv", "med", "eng", "agr", "ind", "art", "pt", "us", "uk", "es", "fr", "de", "it", "ca", "au",
        "ar", "mx", "cl",
    ])

    /// A "+" candidate can run into the next numeric column ("+44 20 7946 0958 2026-1126"). Keep
    /// digit groups only until the number is plausibly complete; reject what cannot be a phone.
    private func trimInternationalNumber(_ source: NSString, _ range: NSRange) -> NSRange? {
        let candidate = source.substring(with: range) as NSString
        var digitCount = 0
        var end = 0
        let whole = NSRange(location: 0, length: candidate.length)
        for group in digitRuns.regex.matches(in: candidate as String, range: whole) {
            digitCount += group.range.length
            end = NSMaxRange(group.range)
            if digitCount >= 10 { break }
        }
        guard (8...15).contains(digitCount) else { return nil }
        if end < candidate.length, candidate.character(at: end) == UInt16(UInt8(ascii: ")")) { end += 1 }
        return NSRange(location: range.location, length: end)
    }

    /// Collapses overlapping matches into one, keeping the kind of the longest.
    private static func mergeOverlapping(
        _ items: [(kind: SensitiveTextKind, range: NSRange)]
    ) -> [(kind: SensitiveTextKind, range: NSRange)] {
        var merged: [(kind: SensitiveTextKind, range: NSRange, longest: Int)] = []
        for item in items.sorted(by: { $0.range.location < $1.range.location }) {
            guard let last = merged.last, item.range.location < NSMaxRange(last.range) else {
                merged.append((item.kind, item.range, item.range.length))
                continue
            }
            let isLonger = item.range.length > last.longest
            merged[merged.count - 1] = (
                isLonger ? item.kind : last.kind, NSUnionRange(last.range, item.range),
                max(last.longest, item.range.length)
            )
        }
        return merged.map { ($0.kind, $0.range) }
    }
}

// MARK: - System data detector (variant B)

/// `NSDataDetector` phone numbers and `mailto:` links, for comparison with the patterns.
struct DataDetectorMatcher: Sendable {
    private let detector: NSDataDetector

    init() throws(SensitiveTextError) {
        let types =
            NSTextCheckingResult.CheckingType.phoneNumber.rawValue | NSTextCheckingResult.CheckingType.link.rawValue
        do { detector = try NSDataDetector(types: types) } catch { throw .dataDetectorUnavailable }
    }

    func matches(in text: String, kinds: Set<SensitiveTextKind>) -> [SensitiveTextMatch] {
        detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            let kind: SensitiveTextKind
            switch result.resultType {
            case .phoneNumber: kind = .phone
            case .link where result.url?.scheme?.lowercased() == "mailto": kind = .email
            default: return nil
            }
            guard kinds.contains(kind), let range = Range(result.range, in: text) else { return nil }
            return SensitiveTextMatch(kind: kind, range: range)
        }
    }
}

// MARK: - Sweep

/// How lines are searched. `documents` asks Vision's document recognizer for its own detected
/// data instead of reading lines (macOS 26 or later).
public enum SensitiveTextMethod: String, Sendable, CaseIterable {
    case patterns
    case dataDetector
    case documents
}

/// A detected item and the whole-pixel rectangle that covers it, top-left origin.
public struct SensitiveRegion: Sendable, Equatable {
    public let kind: SensitiveTextKind
    public let rect: Rect<SourcePixelSpace>
}

/// Locates e-mail addresses and phone numbers in a capture by reading it tile by tile.
public struct SensitiveTextScanner: Sendable {
    private let recognizer = TextRecognizer()
    /// Vision parallelizes inside one request, so more tiles at once buys little and costs memory.
    static let concurrentTiles = 3
    /// Each side of a found box grows by this fraction of its height (at least one pixel), because
    /// Vision's boxes hug the ink and anti-aliasing and descenders sit just outside them.
    static let outsetFraction = 0.15

    /// Side of a fine-sweep tile in resampled pixels (Fosco's 2048 by default).
    let fineTileSide: CGFloat

    public init() { fineTileSide = 2048 }

    /// For the tile-size experiment in the benchmark.
    init(fineTileSide: CGFloat) { self.fineTileSide = fineTileSide }

    /// Regions of `image` that show e-mail addresses or phone numbers. `pixelsPerPoint` is the
    /// capture's backing scale. Throws `CancellationError` when cancelled and a recognition error
    /// when any tile cannot be read, so a caller never takes a partial sweep for a complete one.
    @concurrent
    public func sensitiveRegions(
        in image: CGImage, pixelsPerPoint: Double, languages: [Locale.Language],
        kinds: Set<SensitiveTextKind> = Set(SensitiveTextKind.allCases), method: SensitiveTextMethod = .patterns
    ) async throws -> [SensitiveRegion] {
        try Task.checkCancellation()
        guard !kinds.isEmpty else { return [] }
        let matcher: LineMatcher
        switch method {
        case .patterns: matcher = .patterns(try SensitiveTextMatcher.shared.get())
        case .dataDetector: matcher = .dataDetector(try DataDetectorMatcher())
        case .documents:
            guard #available(macOS 26, *) else { throw SensitiveTextError.methodUnavailable }
            matcher = .documents
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let jobs = TileLayout.standard(pixelsPerPoint: pixelsPerPoint, fineTileSide: fineTileSide).flatMap { layout in
            tileRects(for: bounds.size, layout: layout).map { (rect: $0.intersection(bounds), layout: layout) }
        }.filter { !$0.rect.isEmpty }
        let recognizer = self.recognizer
        let found = try await withThrowingTaskGroup(of: [BoxedMatch].self) { group in
            var next = 0
            var collected: [BoxedMatch] = []
            func enqueue() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask {
                    try await Self.scanTile(
                        of: image, sourceRect: job.rect, layout: job.layout, kinds: kinds, languages: languages,
                        matcher: matcher, recognizer: recognizer)
                }
            }
            for _ in 0..<Self.concurrentTiles { enqueue() }
            while let tile = try await group.next() {
                collected.append(contentsOf: tile)
                enqueue()
            }
            return collected
        }
        try Task.checkCancellation()
        return Self.mergeRegions(found).compactMap { Self.outset($0, within: bounds) }
    }

    enum LineMatcher: Sendable {
        case patterns(SensitiveTextMatcher)
        case dataDetector(DataDetectorMatcher)
        case documents

        func matches(in text: String, kinds: Set<SensitiveTextKind>) -> [SensitiveTextMatch] {
            switch self {
            case .patterns(let matcher): matcher.matches(in: text, kinds: kinds)
            case .dataDetector(let matcher): matcher.matches(in: text, kinds: kinds)
            case .documents: []
            }
        }
    }

    /// A match and its box in source pixels (top-left origin).
    typealias BoxedMatch = (kind: SensitiveTextKind, rect: CGRect)

    private static func scanTile(
        of image: CGImage, sourceRect: CGRect, layout: TileLayout, kinds: Set<SensitiveTextKind>,
        languages: [Locale.Language], matcher: LineMatcher, recognizer: TextRecognizer
    ) async throws -> [BoxedMatch] {
        try Task.checkCancellation()
        let tile = try renderTile(of: image, sourceRect: sourceRect, scale: layout.scale)
        let tileSize = CGSize(width: tile.width, height: tile.height)
        let normalized: [(kind: SensitiveTextKind, box: CGRect)]
        if case .documents = matcher {
            guard #available(macOS 26, *) else { throw SensitiveTextError.methodUnavailable }
            normalized = try await documentMatches(in: tile, languages: languages, kinds: kinds)
        } else {
            let observations = try await recognizer.recognizedObservations(tile, languages: languages).observations
            normalized =
                matchesAcrossFragments(of: observations, tileSize: tileSize, kinds: kinds, matcher: matcher)
                + matchesInAlternateReadings(of: observations, kinds: kinds, matcher: matcher)
        }
        return normalized.compactMap { kind, box in
            guard box.height * tileSize.height >= layout.minimumTextHeight else { return nil }
            // Vision's unit square has a bottom-left origin; the source rect is top-left.
            let rect = CGRect(
                x: sourceRect.minX + box.minX * sourceRect.width,
                y: sourceRect.minY + (1 - box.maxY) * sourceRect.height,
                width: box.width * sourceRect.width, height: box.height * sourceRect.height)
            return (kind, rect)
        }
    }

    /// Vision often breaks one line into several observations, sometimes inside an address
    /// ("ana@acme" + ".com.br") or a number ("(47)" + "9" + "8888-7777"). Each run of neighbouring
    /// fragments is read as the single line it is.
    private static func matchesAcrossFragments(
        of observations: [RecognizedTextObservation], tileSize: CGSize, kinds: Set<SensitiveTextKind>,
        matcher: LineMatcher
    ) -> [(kind: SensitiveTextKind, box: CGRect)] {
        let fragments = observations.compactMap { observation in
            observation.topCandidates(1).first.map { Fragment(text: $0, box: observation.boundingBox.cgRect) }
        }
        let pixelBoxes = fragments.map {
            CGRect(
                x: $0.box.minX * tileSize.width, y: $0.box.minY * tileSize.height, width: $0.box.width * tileSize.width,
                height: $0.box.height * tileSize.height)
        }
        var found: [(kind: SensitiveTextKind, box: CGRect)] = []
        for run in fragmentRuns(pixelBoxes) {
            let line = joinFragments(run.map { (fragments[$0.index].text.string, $0.isGlued) })
            for match in matcher.matches(in: line.text, kinds: kinds) {
                let characters =
                    line.text.distance(
                        from: line.text.startIndex, to: match.range.lowerBound)..<line.text.distance(
                        from: line.text.startIndex, to: match.range.upperBound)
                let box = zip(run, line.offsets).reduce(CGRect.null) { union, member in
                    union.union(fragments[member.0.index].box(of: characters, whenStartingAt: member.1))
                }
                if !box.isNull { found.append((match.kind, box)) }
            }
        }
        return found
    }

    /// A lower-ranked reading sometimes gets right the character the best one got wrong.
    private static func matchesInAlternateReadings(
        of observations: [RecognizedTextObservation], kinds: Set<SensitiveTextKind>, matcher: LineMatcher
    ) -> [(kind: SensitiveTextKind, box: CGRect)] {
        observations.flatMap { observation in
            observation.topCandidates(3).dropFirst().flatMap { reading in
                matcher.matches(in: reading.string, kinds: kinds).map { match in
                    (
                        match.kind,
                        reading.boundingBox(for: match.range)?.boundingBox.cgRect ?? observation.boundingBox.cgRect
                    )
                }
            }
        }
    }

    private struct Fragment {
        let text: RecognizedText
        /// Unit square, bottom-left origin.
        let box: CGRect

        /// Box of the part of this fragment inside `characters`, a range of the joined line in
        /// which this fragment starts at `start`. Null when the range lies elsewhere on the line.
        func box(of characters: Range<Int>, whenStartingAt start: Int) -> CGRect {
            let string = text.string
            let local = characters.clamped(to: start..<(start + string.count))
            guard !local.isEmpty else { return .null }
            let range =
                string.index(
                    string.startIndex, offsetBy: local.lowerBound - start)..<string.index(
                    string.startIndex, offsetBy: local.upperBound - start)
            // Without a box for the match itself, cover the whole fragment rather than nothing.
            guard let matchBox = text.boundingBox(for: range)?.boundingBox.cgRect else { return box }
            // The match's own box can be shorter than the glyphs; the line's box spans their height.
            return CGRect(
                x: matchBox.minX, y: min(matchBox.minY, box.minY), width: matchBox.width,
                height: max(matchBox.maxY, box.maxY) - min(matchBox.minY, box.minY))
        }
    }

    // MARK: Variant C

    /// Matches that Vision's document recognizer reports as detected data, in the tile's unit square.
    @available(macOS 26, *)
    private static func documentMatches(
        in tile: CGImage, languages: [Locale.Language], kinds: Set<SensitiveTextKind>
    ) async throws -> [(kind: SensitiveTextKind, box: CGRect)] {
        var request = RecognizeDocumentsRequest()
        let supported = request.supportedRecognitionLanguages
        let resolved = languages.map { TextRecognizer.match($0, in: supported) }
        let unavailable = zip(languages, resolved).filter { $0.1 == nil }.map(\.0)
        guard unavailable.isEmpty else { throw TextRecognitionError.unsupportedLanguages(unavailable) }
        request.textRecognitionOptions.recognitionLanguages = resolved.compactMap { $0 }
        request.textRecognitionOptions.useLanguageCorrection = false
        request.textRecognitionOptions.automaticallyDetectLanguage = false
        let documents: [DocumentObservation]
        do {
            documents = try await request.perform(on: tile)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            for (stage, devices) in request.supportedComputeStageDevices {
                guard let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) else { continue }
                request.setComputeDevice(cpu, for: stage)
            }
            do { documents = try await request.perform(on: tile) } catch is CancellationError {
                throw CancellationError()
            } catch { throw SensitiveTextError.documentRecognitionFailed }
        }
        var found: [(kind: SensitiveTextKind, box: CGRect)] = []
        for document in documents {
            let container = document.document
            let cells = container.tables.flatMap { $0.rows.flatMap { $0.map(\.content.text) } }
            for text in [container.text] + cells {
                for detected in text.detectedData {
                    let kind: SensitiveTextKind
                    switch detected.match.details {
                    case .emailAddress: kind = .email
                    case .phoneNumber: kind = .phone
                    case .link(let link) where link.url.scheme?.lowercased() == "mailto": kind = .email
                    default: continue
                    }
                    guard kinds.contains(kind) else { continue }
                    found.append((kind, detected.boundingRegion.boundingBox.cgRect))
                }
            }
        }
        return found
    }

    // MARK: Tiles and regions

    /// Crops and resamples one tile onto an opaque white sRGB bitmap, whatever the source format.
    private static func renderTile(of image: CGImage, sourceRect: CGRect, scale: CGFloat) throws -> CGImage {
        let width = Int((sourceRect.width * scale).rounded())
        let height = Int((sourceRect.height * scale).rounded())
        guard width > 0, height > 0, let crop = image.cropping(to: sourceRect),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw SensitiveTextError.tileUnavailable }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(crop, in: bounds)
        guard let tile = context.makeImage() else { throw SensitiveTextError.tileUnavailable }
        return tile
    }

    /// The same text is found by several tiles, sweeps and readings; collapse those into one.
    static func mergeRegions(_ regions: [BoxedMatch]) -> [BoxedMatch] {
        var merged: [BoxedMatch] = []
        for region in regions where region.rect.width.isFinite && region.rect.height.isFinite {
            var current = region
            // A union can newly overlap a region accepted earlier, so keep absorbing until stable.
            while let index = merged.firstIndex(where: { overlapsSubstantially($0.rect, current.rect) }) {
                let other = merged.remove(at: index)
                let kind = other.rect.width >= current.rect.width ? other.kind : current.kind
                current = (kind, other.rect.union(current.rect))
            }
            merged.append(current)
        }
        return merged.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
    }

    private static func overlapsSubstantially(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = a.intersection(b)
        guard !overlap.isNull else { return false }
        let smallerArea = min(a.width * a.height, b.width * b.height)
        return smallerArea > 0 && overlap.width * overlap.height >= 0.25 * smallerArea
    }

    /// Grows a box by `outsetFraction` of its height, rounds outward to whole pixels and clamps it
    /// to the image. Nil when nothing of it lies inside the image.
    static func outset(_ match: BoxedMatch, within bounds: CGRect) -> SensitiveRegion? {
        let pad = max(1, (match.rect.height * outsetFraction).rounded(.up))
        let grown = match.rect.insetBy(dx: -pad, dy: -pad)
        let minX = max(bounds.minX, grown.minX.rounded(.down)), minY = max(bounds.minY, grown.minY.rounded(.down))
        let maxX = min(bounds.maxX, grown.maxX.rounded(.up)), maxY = min(bounds.maxY, grown.maxY.rounded(.up))
        guard maxX > minX, maxY > minY else { return nil }
        return SensitiveRegion(
            kind: match.kind, rect: Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }
}

// MARK: - Tiling

/// One OCR sweep: how the capture is resampled and cut into tiles before Vision reads it.
///
/// Vision shrinks its input to a fixed working size, so small text on a large capture is lost
/// unless the capture is cut into tiles first, and text from a 1x display reads far better
/// enlarged. Fosco measured that tiles up to about 4 megapixels never dropped text on dense screens
/// while 8 megapixel ones occasionally lost a third of it. Sizes are in resampled pixels.
struct TileLayout: Equatable, Sendable {
    var scale: CGFloat
    var tileSide: CGFloat
    /// Text wider than this can be cut by a tile edge without being whole in the next tile.
    var horizontalOverlap: CGFloat
    /// Only has to cover one line of text.
    var verticalOverlap: CGFloat
    /// Matches on shorter text are ignored; lets a sweep leave small print to a finer one.
    var minimumTextHeight: CGFloat = 0

    /// The fine sweep puts text at about two pixels per point, where Vision reads body text best,
    /// with tiles overlapping by half so most text is read twice from different crops. The coarse
    /// one looks at the capture shrunk four times as much, for headline-sized text wider than a
    /// fine tile's overlap, and ignores anything smaller.
    static func standard(pixelsPerPoint: Double, fineTileSide: CGFloat = 2048) -> [TileLayout] {
        let density = max(CGFloat(pixelsPerPoint), 1)
        return [
            TileLayout(
                scale: 2 / density, tileSide: fineTileSide, horizontalOverlap: fineTileSide / 2, verticalOverlap: 192),
            TileLayout(
                scale: 0.5 / density, tileSide: 2880, horizontalOverlap: 1440, verticalOverlap: 384,
                minimumTextHeight: 22),
        ]
    }
}

/// Source-pixel rectangles (top-left origin) covering the image, sized so every tile is at most
/// `tileSide` after resampling.
func tileRects(for size: CGSize, layout: TileLayout) -> [CGRect] {
    let columns = tileSpans(
        length: size.width, tile: layout.tileSide / layout.scale, overlap: layout.horizontalOverlap / layout.scale)
    let rows = tileSpans(
        length: size.height, tile: layout.tileSide / layout.scale, overlap: layout.verticalOverlap / layout.scale)
    return rows.flatMap { row in
        columns.map { column in CGRect(x: column.start, y: row.start, width: column.length, height: row.length) }
    }
}

/// Evenly spread spans of equal length that cover `length` and overlap their neighbour by at least
/// `overlap`.
func tileSpans(length: CGFloat, tile: CGFloat, overlap: CGFloat) -> [(start: CGFloat, length: CGFloat)] {
    guard length > tile, tile > overlap else { return [(0, length)] }
    let count = ((length - overlap) / (tile - overlap)).rounded(.up)
    let span = ((length + (count - 1) * overlap) / count).rounded(.up)
    let step = (length - span) / (count - 1)
    return (0..<Int(count)).map { index in ((CGFloat(index) * step).rounded(.down), span) }
}

// MARK: - Fragment runs

/// Groups text fragments (boxes in pixels, any origin) into left-to-right runs on the same line
/// with no more than a word space between them. `isGlued` marks a fragment that touches the
/// previous one, i.e. the split fell inside a word.
func fragmentRuns(_ boxes: [CGRect]) -> [[(index: Int, isGlued: Bool)]] {
    var runs: [[(index: Int, isGlued: Bool)]] = []
    for index in boxes.indices.sorted(by: { boxes[$0].minX < boxes[$1].minX }) {
        let box = boxes[index]
        var closest: (run: Int, gap: CGFloat, height: CGFloat)?
        for (runIndex, run) in runs.enumerated() {
            guard let last = run.last.map({ boxes[$0.index] }) else { continue }
            let height = max(last.height, box.height)
            let sharedHeight = min(last.maxY, box.maxY) - max(last.minY, box.minY)
            let gap = box.minX - last.maxX
            guard sharedHeight >= 0.5 * min(last.height, box.height), gap >= -0.5 * height, gap <= 1.2 * height
            else { continue }
            if closest.map({ abs(gap) < abs($0.gap) }) ?? true { closest = (runIndex, gap, height) }
        }
        if let closest {
            runs[closest.run].append((index, closest.gap < 0.15 * closest.height))
        } else {
            runs.append([(index, false)])
        }
    }
    return runs
}

/// Concatenates the fragments of a run, with a space unless a fragment is glued to the previous
/// one. `offsets` is where each fragment starts in the result, in characters.
func joinFragments(_ parts: [(text: String, isGlued: Bool)]) -> (text: String, offsets: [Int]) {
    var text = ""
    var offsets: [Int] = []
    for (position, part) in parts.enumerated() {
        if position > 0, !part.isGlued { text += " " }
        offsets.append(text.count)
        text += part.text
    }
    return (text, offsets)
}
