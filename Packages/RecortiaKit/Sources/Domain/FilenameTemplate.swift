import Foundation

public enum FilenameTemplateError: Error, Hashable, Sendable {
    case empty
    case tooLong
    /// A period first or last, or two in a row: a hidden file, or `..` before the extension.
    case misplacedPeriod
    /// Anything but letters, digits, spaces and `- _ . ( )`: path separators, emoji, controls.
    case unsupportedCharacter
    /// A brace that does not enclose one of `FilenameTemplate.Placeholder`.
    case unknownPlaceholder
}

/// How saved and dragged files are named (FR-07, A-9): fixed text plus a closed set of
/// placeholders. None carries window titles, app names or recognized text: those are captured
/// content and would leak into file names. GitHub uploads keep their per-intent path (ADR-006)
/// and do not use it. A value exists only once `init(validating:)` has
/// accepted its text, so everything downstream renders it without checking again.
public struct FilenameTemplate: Hashable, Sendable {
    public enum Placeholder: String, CaseIterable, Hashable, Sendable {
        case date, time, counter
    }

    private enum Piece: Hashable, Sendable {
        case text(String)
        case placeholder(Placeholder)
    }

    /// Recortia's own naming, "Recortia 2026-11-20 at 14.32.05".
    public static let `default` = FilenameTemplate(
        text: "Recortia {date} at {time}",
        pieces: [
            .text("Recortia "), .placeholder(.date), .text(" at "), .placeholder(.time),
        ])

    /// In UTF-8 bytes. Each placeholder renders at most 4 bytes longer than it is written, so a
    /// name at this limit, with " (1000)" and an extension, stays below the 255-byte limit of
    /// APFS and HFS+ and is never truncated.
    public static let maximumLength = 100

    /// The accepted text, without surrounding spaces.
    public let text: String
    private let pieces: [Piece]

    private init(text: String, pieces: [Piece]) {
        self.text = text
        self.pieces = pieces
    }

    public init(validating input: String) throws(FilenameTemplateError) {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw .empty }
        guard text.utf8.count <= Self.maximumLength else { throw .tooLong }
        guard !text.hasPrefix("."), !text.hasSuffix("."), !text.contains("..") else { throw .misplacedPeriod }
        var pieces: [Piece] = []
        var literal = ""
        var remaining = Substring(text)
        while let character = remaining.first {
            remaining.removeFirst()
            switch character {
            case "{":
                guard let close = remaining.firstIndex(of: "}"),
                    let placeholder = Placeholder(rawValue: String(remaining[..<close]))
                else { throw .unknownPlaceholder }
                if !literal.isEmpty { pieces.append(.text(literal)) }
                literal = ""
                pieces.append(.placeholder(placeholder))
                remaining = remaining[remaining.index(after: close)...]
            case "}": throw .unknownPlaceholder
            default:
                guard Self.isAllowed(character) else { throw .unsupportedCharacter }
                literal.append(character)
            }
        }
        if !literal.isEmpty { pieces.append(.text(literal)) }
        self.init(text: text, pieces: pieces)
    }

    /// Letters and digits of any script, with their combining accents, plus space and `- _ . ( )`.
    /// Enclosing marks and variation selectors are refused, so a keycap or emoji sequence built
    /// on a digit is not mistaken for one.
    private static func isAllowed(_ character: Character) -> Bool {
        if character.isASCII { return character.isLetter || character.isNumber || " -_.()".contains(character) }
        return character.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                .decimalNumber, .spacingMark:
                true
            case .nonspacingMark: !scalar.properties.isVariationSelector
            default: false
            }
        }
    }

    /// The name for a snapshot made at `date`, with the format's extension.
    public func name(for date: Date, format: ExportFormat, timeZone: TimeZone = .current) -> ExportName {
        func formatted(_ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = pattern
            return formatter.string(from: date)
        }
        var parts = [""]
        for piece in pieces {
            switch piece {
            case .text(let text): parts[parts.count - 1] += text
            case .placeholder(.date): parts[parts.count - 1] += formatted("yyyy-MM-dd")
            // Colons are path separators in Finder, so the time uses periods, as macOS does.
            case .placeholder(.time): parts[parts.count - 1] += formatted("HH.mm.ss")
            case .placeholder(.counter): parts.append("")
            }
        }
        parts[parts.count - 1] += ".\(format.fileExtension)"
        return ExportName(parts: parts)
    }
}

extension FilenameTemplate: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    /// A stored template this version cannot accept (written by a later version, edited by hand,
    /// or not even a string) names files the default way instead of failing the whole preferences
    /// blob, which would lose every other setting (PREF-01).
    public init(from decoder: any Decoder) throws {
        let text: String
        do {
            text = try decoder.singleValueContainer().decode(String.self)
        } catch is DecodingError {
            self = .default
            return
        }
        do throws(FilenameTemplateError) {
            self = try FilenameTemplate(validating: text)
        } catch {
            self = .default
        }
    }
}

/// A rendered file name and how it is numbered while the name is taken (FR-07).
public struct ExportName: Hashable, Sendable {
    /// The name split at each `{counter}`; a single part when the template has none.
    private let parts: [String]

    init(parts: [String]) {
        self.parts = parts
    }

    /// A finished name that numbers with " (n)".
    package init(literal name: String) {
        parts = [name]
    }

    /// The number `name` carries when it is this counting name with some number: digits without
    /// a leading zero, at most nine of them, so resuming above it cannot overflow. Text after
    /// `{counter}` may start with digits, so each length is tried against the whole name.
    public func number(in name: String) -> Int? {
        guard counts, name.hasPrefix(parts[0]) else { return nil }
        let digits = name.dropFirst(parts[0].count).prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return (1...min(9, digits.count)).lazy.compactMap { Int(digits.prefix($0)) }.first {
            $0 > 0 && self.name(attempt: $0) == name
        }
    }

    /// Whether the name carries its own number, the template's `{counter}`.
    public var counts: Bool { parts.count > 1 }

    /// Attempt 1 is the first choice. A counting name becomes number `attempt`; any other name
    /// gets " (attempt)" before its extension.
    public func name(attempt: Int) -> String {
        counts ? parts.joined(separator: String(attempt)) : ExportFilename.deduplicated(parts[0], attempt: attempt)
    }
}
