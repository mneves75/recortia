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
        #expect(!prefs.autoCopy && !prefs.autoSave && !prefs.launchAtLogin && !prefs.updateChecksEnabled)
        #expect(!prefs.automaticScrollingEnabled)
        #expect(!prefs.captureShowsCursor)
        let round = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(round == prefs)
    }

    @Test("Capture delay is clamped to 0…10 seconds")
    func captureDelayClamp() {
        #expect(CaptureRequest.clampedDelay(-3) == 0)
        #expect(CaptureRequest.clampedDelay(4) == 4)
        #expect(CaptureRequest.clampedDelay(99) == 10)
    }
}
