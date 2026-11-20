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
    /// A match's box could not be mapped onto the image. The sweep fails rather than drop the match.
    case regionOutsideImage
    /// The capture needs more tiles than one sweep may read (`SensitiveTextScanner.maximumTiles`).
    case tooManyTiles
    /// A tile or the whole sweep found more candidates than it may keep; the sweep fails closed.
    case tooManyMatches
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

    /// Longest text, in UTF-16 units, that one regex call reads. Longer lines are read in windows
    /// that overlap by `windowOverlap`, which exceeds the longest match any pattern can make (every
    /// repetition is bounded), so each match is whole in at least one window and the work grows
    /// linearly with the line.
    static let windowLength = 4096
    static let windowOverlap = 1024

    public func matches(
        in text: String, kinds: Set<SensitiveTextKind> = Set(SensitiveTextKind.allCases)
    ) -> [SensitiveTextMatch] {
        let source = text as NSString
        let bridged = source as String
        var found: [(kind: SensitiveTextKind, range: NSRange)] = []
        for start in stride(
            from: 0, to: max(source.length - Self.windowOverlap, 1), by: Self.windowLength - Self.windowOverlap)
        {
            let window = NSRange(location: start, length: min(Self.windowLength, source.length - start))
            for detector in compiled where kinds.contains(detector.pattern.kind) {
                // Transparent bounds let the edge look-arounds see past the window, so a window never
                // starts a match inside a longer number or ends one inside a longer domain.
                for result in detector.regex.matches(
                    in: bridged, options: [.withTransparentBounds, .withoutAnchoringBounds], range: window)
                {
                    guard let range = refine(detector.pattern.refinement, source, result.range) else { continue }
                    found.append((detector.pattern.kind, range))
                }
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

    /// Letters of any script are allowed, so "joão@…" is not cut to "o@…" (RFC 6531).
    private static let localChars = #"[\p{L}\p{M}0-9._%+\-…]"#
    /// At most 64 characters plus two apostrophe-joined parts ("o'brien", RFC 5322 atext); an
    /// apostrophe never starts or ends it, so quoting with ' leaves the quote unmasked.
    ///
    /// Every pattern that starts with it starts only where a run of local characters starts
    /// (`localStart`), so a line is not retried at every character of a long run. A run longer than
    /// RFC 5321's 64 characters before the "@" is therefore not taken for an address.
    private static let localPart = #"\#(localChars){1,64}(?:['’]\#(localChars){1,32}){0,2}"#
    private static let localStart = #"(?<!\#(localChars))"#
    /// Suffixes accepted after an OCR-inserted space ("gmail. com"). Lowercase only, and no suffix
    /// that doubles as a word ("me", "us"), so "x@exemplo.com. Me liga" keeps its next sentence.
    private static let spacedSuffix = #"(?-i:com|net|org|br|io|dev|app|edu|gov)(?![a-z0-9\-])"#
    private static let fullDomain =
        #"(?:[a-z0-9\-]{1,63}(?:\.\s(?=\#(spacedSuffix))|\.)){1,8}[a-z]{2,24}(?![a-z0-9\-])"#
    /// Domain cut off by the UI: "maria@gm…".
    private static let truncatedDomain = #"[a-z0-9.\-]{0,253}(?:…|\.{3})"#
    private static let mailProviders = "gmail|hotmail|outlook|yahoo|icloud|live|uol|bol|terra|proton(?:mail)?"
    /// One separator between digit groups (space, dot, any hyphen or dash).
    private static let sep = #"[\s.\-‐-—]"#
    /// Do not start inside a longer number, an id (#123…) or a decimal.
    private static let leftEdge = #"(?<![\d#.,+\-])"#
    /// Do not stop inside a longer number or a decimal.
    private static let rightEdge = #"(?!\d)(?![.,\-]\d)"#
    /// A word that announces a phone number, then up to two spaces.
    private static let phoneLabel =
        #"(?<=\b(?:phone|tel|telephone|mobile|cell|call|fax|whatsapp|whats|telefone|fone|celular|cel|ligue)[.:]?\s{1,2})"#
    /// Brazilian area codes (DDD) in use.
    private static let areaCode = "(?:1[1-9]|2[12478]|3[1-578]|4[1-9]|5[1345]|6[1-9]|7[134579]|8[1-9]|9[1-9])"

    static let patterns: [Pattern] = [
        // name@domain.tld, with an optional OCR space after a dot in the local part.
        Pattern(
            name: "email", kind: .email,
            source: #"\#(localStart)(?:\#(localPart)\.\s)?\#(localPart)@(?:\#(fullDomain)|\#(truncatedDomain))"#,
            refinement: .rejectGitRemote),
        // Top-level domain damaged by OCR: "x@startup-io", "x@startup.1o", "x@gmail,corn".
        Pattern(
            name: "email-damaged-domain", kind: .email,
            source: #"\#(localStart)\#(localPart)@[a-z][a-z0-9.\-]{0,253}[.,\-][a-z0-9]{2,5}(?![a-z0-9\-])"#,
            refinement: .acceptDamagedDomain),
        // "@" misread as a letter in front of a well-known mail provider ("anadgmail.com").
        Pattern(
            name: "email-lost-at", kind: .email,
            source:
                #"(?<![a-z0-9._%+\-])[a-z0-9._%+\-]{2,64}(?<![.@])(?:\#(mailProviders))\.(?:com|me)(?:\.br)?(?![a-z0-9\-])"#,
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
        // A digit run with no separators, or a Brazilian number without its area code, only right after
        // a word that announces a phone ("Phone: 2025550100", "Celular: 987654321", "Tel 4004-5566").
        // Elsewhere such runs are IDs, timestamps and amounts.
        Pattern(
            name: "phone-labelled", kind: .phone,
            source:
                #"\#(phoneLabel)(?:[2-9]\d{9}|9\#(sep)?\d{4}\#(sep)?\d{4}|[2-5]\d{3}\#(sep)?\d{4})\#(rightEdge)"#,
            refinement: .none),
        // Any other number written with a country code: +351 912 345 678.
        Pattern(
            name: "phone-international", kind: .phone, source: #"(?<![\d#])\+\d{1,3}(?:\#(sep)?\(?\d{1,12}\)?){1,8}"#,
            refinement: .trimInternationalNumber),
    ]

    /// "git@github.com:org/repo.git" is an SSH remote, not an address: "git@" followed by the host,
    /// a colon and a path. "git@example.com" alone, or before ": text", is a mailbox.
    private static func rejectGitRemote(_ source: NSString, _ range: NSRange) -> NSRange? {
        let colon = NSMaxRange(range)
        guard source.substring(with: range).lowercased().hasPrefix("git@"), colon + 1 < source.length,
            source.character(at: colon) == UInt16(UInt8(ascii: ":")),
            let next = Unicode.Scalar(source.character(at: colon + 1)),
            !CharacterSet.whitespacesAndNewlines.contains(next)
        else { return range }
        return nil
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
    /// whole digit groups while the number stays within its plan's length: 11 digits after "+1 "
    /// (NANP), 13 after "+55 " (Brazil), E.164's 15 otherwise. Reject what cannot be a phone.
    private func trimInternationalNumber(_ source: NSString, _ range: NSRange) -> NSRange? {
        let candidate = source.substring(with: range) as NSString
        let whole = NSRange(location: 0, length: candidate.length)
        let groups = digitRuns.regex.matches(in: candidate as String, range: whole).map(\.range)
        let countryCode = groups.first.map { candidate.substring(with: $0) }
        let limit = countryCode == "1" ? 11 : countryCode == "55" ? 13 : 15
        var digitCount = 0
        var end = 0
        for group in groups {
            guard digitCount + group.length <= limit else { break }
            digitCount += group.length
            end = NSMaxRange(group)
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
        // A total order, so the result never depends on pattern or window order.
        let ordered = items.sorted {
            ($0.range.location, -$0.range.length, $0.kind.rawValue) < (
                $1.range.location, -$1.range.length, $1.kind.rawValue
            )
        }
        for item in ordered {
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
        let jobs = try Self.tileJobs(for: bounds.size, pixelsPerPoint: pixelsPerPoint, fineTileSide: fineTileSide)
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
                // Throwing here cancels the tiles still in flight.
                guard collected.count <= Self.maximumMatches else { throw SensitiveTextError.tooManyMatches }
                enqueue()
            }
            return collected
        }
        return try Self.finalRegions(found, within: bounds)
    }

    /// Budgets that keep one sweep's work and memory bounded. Exceeding one fails the sweep with a
    /// typed error; nothing is dropped. An admitted capture (40 MP) needs about 400 tiles.
    static let maximumTiles = 1024
    static let maximumMatchesPerTile = 512
    static let maximumMatches = 4096

    static func tileJobs(
        for size: CGSize, pixelsPerPoint: Double, fineTileSide: CGFloat
    ) throws(SensitiveTextError) -> [(rect: CGRect, layout: TileLayout)] {
        let bounds = CGRect(origin: .zero, size: size)
        let jobs = TileLayout.standard(pixelsPerPoint: pixelsPerPoint, fineTileSide: fineTileSide).flatMap { layout in
            tileRects(for: size, layout: layout).map { (rect: $0.intersection(bounds), layout: layout) }
        }.filter { !$0.rect.isEmpty }
        guard jobs.count <= maximumTiles else { throw .tooManyTiles }
        return jobs
    }

    /// Merges and outsets the collected matches. Any match that cannot be mapped onto the image fails
    /// the sweep, and so does a cancellation that arrives while this runs.
    static func finalRegions(_ found: [BoxedMatch], within bounds: CGRect) throws -> [SensitiveRegion] {
        try Task.checkCancellation()
        guard found.count <= maximumMatches else { throw SensitiveTextError.tooManyMatches }
        guard
            found.allSatisfy({
                $0.rect.minX.isFinite && $0.rect.minY.isFinite && $0.rect.width.isFinite && $0.rect.height.isFinite
            })
        else { throw SensitiveTextError.regionOutsideImage }
        let regions = try mergeRegions(found).map { match throws(SensitiveTextError) in
            try outset(match, within: bounds)
        }
        try Task.checkCancellation()
        return regions
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
        guard normalized.count <= maximumMatchesPerTile else { throw SensitiveTextError.tooManyMatches }
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
            for line in fragmentReadings(run.map { (fragments[$0.index].text.string, $0.isGlued) }) {
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
    /// Inputs are sorted by a total order first, so the result does not depend on the order in
    /// which tiles finish. Callers reject non-finite boxes before merging (`finalRegions`).
    static func mergeRegions(_ regions: [BoxedMatch]) -> [BoxedMatch] {
        var merged: [BoxedMatch] = []
        let ordered = regions.sorted {
            ($0.rect.minY, $0.rect.minX, $0.rect.maxY, $0.rect.maxX, $0.kind.rawValue)
                < ($1.rect.minY, $1.rect.minX, $1.rect.maxY, $1.rect.maxX, $1.kind.rawValue)
        }
        for region in ordered {
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
    /// to the image. Throws when nothing of it lies inside the image: a match must never vanish.
    static func outset(_ match: BoxedMatch, within bounds: CGRect) throws(SensitiveTextError) -> SensitiveRegion {
        let pad = max(1, (match.rect.height * outsetFraction).rounded(.up))
        let grown = match.rect.insetBy(dx: -pad, dy: -pad)
        let minX = max(bounds.minX, grown.minX.rounded(.down)), minY = max(bounds.minY, grown.minY.rounded(.down))
        let maxX = min(bounds.maxX, grown.maxX.rounded(.up)), maxY = min(bounds.maxY, grown.maxY.rounded(.up))
        guard maxX > minX, maxY > minY else { throw .regionOutsideImage }
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
/// The joined line, then, when a word-sized gap fell next to "@", a dot or a hyphen, the same line
/// with those gaps closed. Vision can split "ana@acme" from ".com.br" with a gap as wide as a word
/// space; reading both forms costs a second match pass and can only add masks.
func fragmentReadings(_ parts: [(text: String, isGlued: Bool)]) -> [(text: String, offsets: [Int])] {
    let dashes: Set<Character> = ["-", "‐", "‑", "‒", "–", "—"]
    var closed = parts
    for index in parts.indices.dropFirst() where !parts[index].isGlued {
        let left = parts[index - 1].text.last, right = parts[index].text.first
        let continues =
            left == "@" || left.map(dashes.contains) == true || right == "@" || right == "."
            || right.map(dashes.contains) == true
        if continues { closed[index].isGlued = true }
    }
    let spaced = joinFragments(parts)
    guard closed.map(\.isGlued) != parts.map(\.isGlued) else { return [spaced] }
    return [spaced, joinFragments(closed)]
}

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
