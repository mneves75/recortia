import Foundation
import Testing

@testable import Domain

// Failure modes (FR-07, A-9): a template that escapes the folder, hides the file, overflows the
// name limit, smuggles emoji or an unknown placeholder into file names, changes the default name,
// or loses the person's other preferences when a stored template cannot be read.
@Suite("Filename templates (FR-07, A-9)")
struct FilenameTemplateTests {
    /// 2026-11-20 14:32:05 UTC.
    private let date = Date(timeIntervalSince1970: 1_795_185_125)

    private func name(_ text: String, format: ExportFormat = .png, attempt: Int = 1) throws -> String {
        try FilenameTemplate(validating: text).name(for: date, format: format, timeZone: .gmt).name(attempt: attempt)
    }

    @Test("The default template keeps today's name")
    func defaultName() {
        let name = FilenameTemplate.default.name(for: date, format: .png, timeZone: .gmt).name(attempt: 1)
        #expect(name == "Recortia 2026-11-20 at 14.32.05.png")
    }

    @Test(
        "Each placeholder renders, and fixed text stays as typed",
        arguments: [
            ("{date}", "2026-11-20.png"),
            ("{time}", "14.32.05.png"),
            ("{counter}", "1.png"),
            ("Captura {date} às {time} ({counter})", "Captura 2026-11-20 às 14.32.05 (1).png"),
            ("  Shot_1-a.b  ", "Shot_1-a.b.png"),
        ])
    func tokens(template: String, expected: String) throws {
        #expect(try name(template) == expected)
    }

    @Test("JPEG names end in .jpg")
    func jpegExtension() throws {
        #expect(try name("Shot", format: .jpeg(quality: 0.8)) == "Shot.jpg")
    }

    @Test("A counting name numbers itself on a collision; any other name keeps the (n) suffix")
    func collisions() throws {
        #expect(try name("Shot {counter}", attempt: 2) == "Shot 2.png")
        #expect(try name("{counter}-{counter}", attempt: 3) == "3-3.png")
        #expect(try name("Shot", attempt: 2) == "Shot (2).png")
        #expect(try name("Shot {date}", attempt: 3) == "Shot 2026-11-20 (3).png")
    }

    @Test(
        "Unusable templates are refused with their reason",
        arguments: [
            ("", FilenameTemplateError.empty),
            ("   ", .empty),
            ("/", .unsupportedCharacter),
            ("a/b", .unsupportedCharacter),
            ("a:b", .unsupportedCharacter),
            ("a\\b", .unsupportedCharacter),
            ("..", .leadingDot),
            (".hidden", .leadingDot),
            ("Shot 😀", .unsupportedCharacter),
            ("Shot 1️⃣", .unsupportedCharacter),
            ("tab\tname", .unsupportedCharacter),
            ("{weekday}", .unknownPlaceholder),
            ("{date", .unknownPlaceholder),
            ("date}", .unknownPlaceholder),
            (String(repeating: "a", count: FilenameTemplate.maximumLength + 1), .tooLong),
            (String(repeating: "ç", count: FilenameTemplate.maximumLength / 2 + 1), .tooLong),
        ])
    func refusals(template: String, expected: FilenameTemplateError) {
        #expect(throws: expected) { try FilenameTemplate(validating: template) }
    }

    @Test("The longest accepted template still fits the file-system name limit with its number")
    func longestFits() throws {
        let longest = String(repeating: "{date}", count: FilenameTemplate.maximumLength / 6)
        let rendered = try name(longest, format: .jpeg(quality: 1), attempt: 1000)
        #expect(rendered.utf8.count < 255)
    }

    @Test("A stored template round-trips; one this version cannot read decodes as the default")
    func decoding() throws {
        let template = try FilenameTemplate(validating: "Shot {counter}")
        let data = try JSONEncoder().encode(template)
        #expect(try JSONDecoder().decode(FilenameTemplate.self, from: data) == template)
        let unreadable = try JSONEncoder().encode("{weekday}/x")
        #expect(try JSONDecoder().decode(FilenameTemplate.self, from: unreadable) == .default)
    }

    @Test("Preferences without a template, from before A-9, name files the default way")
    func legacyPreferences() throws {
        var legacy = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any])
        legacy.removeValue(forKey: "filenameTemplateChoice")
        let decoded = try JSONDecoder().decode(
            Preferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.filenameTemplate == .default)
        #expect(decoded.exportOptions.filenameTemplate == .default)
    }
}
