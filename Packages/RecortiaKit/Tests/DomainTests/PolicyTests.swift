import Foundation
import Testing

@testable import Domain

@Suite("Limits, filenames, preferences, and export policy")
struct PolicyTests {

    @Test("Collision names append a counter before the extension")
    func collisionName() {
        #expect(ExportFilename.deduplicated("Recortia 1.png", attempt: 2) == "Recortia 1 (2).png")
        #expect(ExportFilename.deduplicated("Recortia 1.png", attempt: 1) == "Recortia 1.png")
    }

    @Test("Side-effect preferences default to off")
    func preferencesDefaults() throws {
        let prefs = Preferences()
        #expect(!prefs.autoCopy && !prefs.autoSave && !prefs.updateChecksEnabled)
        #expect(!prefs.automaticScrollingEnabled)
        #expect(!prefs.captureShowsCursor)
        let round = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(round == prefs)
    }

    /// The keys 0.14.0's synthesized decoder required. A blob missing any of them makes 0.14 fall
    /// back to default settings, so rolling back would lose the person's preferences (PREF-01).
    private struct Release014Preferences: Decodable {
        let schemaVersion: Int
        let hasCompletedOnboarding: Bool
        let captureDelaySeconds: Int
        let captureShowsCursor: Bool
        let captureIncludesWindowShadow: Bool
        let autoCopy: Bool
        let autoSave: Bool
        let launchAtLogin: Bool
        let updateChecksEnabled: Bool
        let automaticScrollingEnabled: Bool
        let defaultExportFormat: String
        let jpegQuality: Double
        let defaultExportScale: Double
        let ocrTextMode: String
        let pinDefaultOpacity: Double
    }

    @Test("A blob this build writes still decodes in 0.14.0's shape")
    func rollbackTo014KeepsPreferences() throws {
        var prefs = Preferences()
        prefs.autoCopy = true
        prefs.captureDelaySeconds = 3
        let old = try JSONDecoder().decode(Release014Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(old.autoCopy && old.captureDelaySeconds == 3)
        #expect(!old.launchAtLogin, "the login item, not this key, is the truth")
    }

    @Test("Export formats round-trip, and the encodings builds before HEIC wrote decode unchanged")
    func exportFormatCoding() throws {
        for format in [ExportFormat.png, .jpeg(quality: 0.8), .heic(quality: 0.7)] {
            #expect(try JSONDecoder().decode(ExportFormat.self, from: JSONEncoder().encode(format)) == format)
        }
        let png = try JSONDecoder().decode(ExportFormat.self, from: Data(#"{"png":{}}"#.utf8))
        let jpeg = try JSONDecoder().decode(ExportFormat.self, from: Data(#"{"jpeg":{"quality":0.9}}"#.utf8))
        #expect(png == .png && jpeg == .jpeg(quality: 0.9))
        #expect(ExportFormat.heic(quality: 0.5).fileExtension == "heic")
        #expect(ExportFormat.heic(quality: 0.5).utTypeIdentifier == "public.heic")
        #expect(throws: ExportOptionsError.invalidQuality) {
            try ExportOptions(format: .heic(quality: .nan)).validated()
        }
        #expect(throws: ExportOptionsError.translucentJPEGBackground) {
            try ExportOptions(format: .heic(quality: 0.5), jpegBackground: RGBA(r: 0, g: 0, b: 0, a: 10)).validated()
        }
    }

    @Test("Capture delay is clamped to 0…10 seconds")
    func captureDelayClamp() {
        #expect(CaptureRequest.clampedDelay(-3) == 0)
        #expect(CaptureRequest.clampedDelay(4) == 4)
        #expect(CaptureRequest.clampedDelay(99) == 10)
    }
}
