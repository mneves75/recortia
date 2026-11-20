import Domain
import Foundation
import Testing

/// Independent review of A-9: characters that render as something else in Finder must never reach
/// a file name, while ordinary accented and non-Latin letters still do.
@Suite("Filename templates: spoofing characters (T1 review)")
struct FilenameTemplateReviewTests {
    @Test(
        "Format, separator and look-alike characters are refused",
        arguments: [
            "Shot\u{202E}gnp.exe",  // right-to-left override: reverses the visible extension
            "Shot\u{200D}x",  // zero-width joiner
            "Shot\u{200B}x",  // zero-width space
            "Shot\u{00A0}x",  // no-break space inside the name
            "a\u{FF0F}b",  // fullwidth solidus, looks like a path separator
            "a\u{2215}b",  // division slash
            "Shot\u{FEFF}",  // byte-order mark
            "Shot\u{0000}x",  // NUL
        ])
    func spoofingCharactersRefused(_ text: String) {
        #expect(throws: FilenameTemplateError.unsupportedCharacter) { try FilenameTemplate(validating: text) }
    }

    @Test(
        "Accented and non-Latin letters are accepted (control)",
        arguments: ["Captura e\u{0301}", "Снимок {counter}", "截图 {date}", "스크린샷"])
    func lettersAccepted(_ text: String) throws {
        let template = try FilenameTemplate(validating: text)
        let name = template.name(for: Date(timeIntervalSince1970: 0), format: .png, timeZone: .gmt).name(attempt: 1)
        #expect(name.hasSuffix(".png") && !name.contains("/"))
    }
}
