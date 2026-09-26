import Foundation

/// Character error rate: Levenshtein edits over extended grapheme clusters divided by the
/// reference length. Accents and punctuation count as characters; only whitespace layout is
/// normalized, because OCR line segmentation is not a character error.
public enum CER {
    public struct Tally: Sendable, Equatable {
        public var edits = 0
        public var referenceCharacters = 0

        public init() {}

        public var rate: Double { referenceCharacters == 0 ? 0 : Double(edits) / Double(referenceCharacters) }

        public mutating func add(reference: String, hypothesis: String) {
            let r = CER.normalized(reference), h = CER.normalized(hypothesis)
            edits += CER.editDistance(Array(r), Array(h))
            referenceCharacters += r.count
        }
    }

    /// NFC, every whitespace run collapsed to one space, trimmed.
    public static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    public static func rate(reference: String, hypothesis: String) -> Double {
        var tally = Tally()
        tally.add(reference: reference, hypothesis: hypothesis)
        return tally.rate
    }

    public static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
