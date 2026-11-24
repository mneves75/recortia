import Domain
import Foundation
import Imaging
import Testing

@testable import Features

// Failure modes (FR-08, primary language): the chosen language not tried first; the others
// reordered or dropped; a language this Mac's Vision no longer reports still requested or kept
// stored; a blank or hand-edited identifier stored; Vision reporting nothing erasing the choice.
@Suite("Primary recognition language (FR-08)")
@MainActor
struct PrimaryRecognitionLanguageTests {
    private func requested(primary: String?, supported: [String]? = nil) async -> (EditorHarness, [String]?) {
        let h = EditorHarness()
        if let supported { h.recognizer.languages = supported.map { Locale.Language(identifier: $0) } }
        h.settings.update { $0.primaryRecognitionLanguage = primary }
        h.recognizer.lines = [OCRResult.Line(text: "x", confidence: 1, box: Rect(x: 0, y: 0, width: 1, height: 1))]
        await h.model.recognizeText()
        return (h, h.recognizer.requestedLanguages.last?.map(\.minimalIdentifier))
    }

    @Test("The primary language is tried first and the others keep their order")
    func primaryFirst() async {
        #expect(await requested(primary: nil).1 == ["en", "pt"])
        #expect(await requested(primary: "pt-Latn-BR").1 == ["pt", "en"])
        #expect(await requested(primary: "en-Latn-US").1 == ["en", "pt"])
        // A language outside English and Portuguese goes ahead of both.
        #expect(await requested(primary: "fr-Latn-FR").1 == ["fr", "en", "pt"])
        #expect(await requested(primary: "ja-Jpan-JP", supported: ["ja-JP", "ko-KR"]).1 == ["ja", "ko"])
        #expect(await requested(primary: "ko-Kore-KR", supported: ["ja-JP", "ko-KR"]).1 == ["ko", "ja"])
    }

    @Test("A language Vision no longer reports falls back to Automatic and is forgotten")
    func unsupportedFallsBack() async {
        let (h, languages) = await requested(primary: "de-Latn-DE")
        #expect(languages == ["en", "pt"])
        #expect(h.settings.preferences.primaryRecognitionLanguage == nil)
    }

    @Test("Vision reporting no languages keeps the choice")
    func emptyListKeepsChoice() {
        let settings = SettingsStore(storage: MemoryPreferenceStorage())
        settings.update { $0.primaryRecognitionLanguage = "pt-Latn-BR" }
        settings.forgetUnsupportedPrimaryRecognitionLanguage(supported: [])
        #expect(settings.preferences.primaryRecognitionLanguage == "pt-Latn-BR")
        settings.forgetUnsupportedPrimaryRecognitionLanguage(supported: [Locale.Language(identifier: "pt-BR")])
        #expect(settings.preferences.primaryRecognitionLanguage == "pt-Latn-BR")
        settings.forgetUnsupportedPrimaryRecognitionLanguage(supported: [Locale.Language(identifier: "en-US")])
        #expect(settings.preferences.primaryRecognitionLanguage == nil)
    }

    @Test("Only a well-formed identifier is stored, in its full form")
    func sanitized() {
        let settings = SettingsStore(storage: MemoryPreferenceStorage())
        for odd in ["", "   ", "pt BR", "en-US; rm", "ç-BR", String(repeating: "a", count: 65)] {
            settings.update { $0.primaryRecognitionLanguage = "pt-Latn-BR" }
            settings.update { $0.primaryRecognitionLanguage = odd }
            #expect(settings.preferences.primaryRecognitionLanguage == nil, "\(odd.debugDescription)")
        }
        settings.update { $0.primaryRecognitionLanguage = "pt-BR" }
        #expect(settings.preferences.primaryRecognitionLanguage == "pt-Latn-BR")
    }
}
