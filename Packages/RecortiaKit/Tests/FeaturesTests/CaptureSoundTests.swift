import Domain
import Foundation
import Testing

@testable import Features

// Failure modes (FR-01, A-12): a sound played by default, for Capture Text, for a canceled or
// failed capture, more than once per capture, or a preference blob from before A-12 that no
// longer decodes.
@Suite("Capture sound (FR-01, A-12)")
@MainActor
struct CaptureSoundTests {
    private func capture(_ h: CaptureHarness, purpose: CapturePurpose = .edit) async {
        h.coordinator.start(.region, purpose: purpose)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("captured") { h.completions.count == 1 }
    }

    @Test("Off by default, including for preferences saved before A-12")
    func offByDefault() async throws {
        #expect(!Preferences().playsCaptureSound)
        var legacy = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any])
        legacy.removeValue(forKey: "playsCaptureSoundChoice")
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!decoded.playsCaptureSound)
        let h = CaptureHarness()
        await capture(h)
        #expect(h.sound.playCount == 0)
    }

    @Test("Turned on, a successful capture plays it once")
    func playsOnce() async {
        let h = CaptureHarness()
        h.settings.update { $0.playsCaptureSound = true }
        await capture(h)
        await drain()
        #expect(h.sound.playCount == 1)
    }

    @Test("Capture Text never plays it")
    func silentForText() async {
        let h = CaptureHarness()
        h.settings.update { $0.playsCaptureSound = true }
        await capture(h, purpose: .recognizeText)
        #expect(h.sound.playCount == 0)
    }

    @Test("A failed or canceled capture never plays it")
    func silentOnFailure() async {
        let failed = CaptureHarness()
        failed.settings.update { $0.playsCaptureSound = true }
        failed.capture.immediateCaptureError = .system(code: 5)
        failed.coordinator.start(.region)
        failed.coordinator.commitRegion(failed.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("failed") { failed.coordinator.state == .failed(.system(code: 5)) }
        #expect(failed.sound.playCount == 0)

        let canceled = CaptureHarness()
        canceled.settings.update { $0.playsCaptureSound = true }
        canceled.coordinator.start(.region)
        canceled.coordinator.cancel()
        await drain()
        #expect(canceled.sound.playCount == 0)
    }
}
