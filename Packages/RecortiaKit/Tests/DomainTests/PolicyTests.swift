import Foundation
import Testing

@testable import Domain

@Suite("Limits, filenames, preferences, and export policy")
struct PolicyTests {
    @Test("Import limits match SPEC FR-03")
    func importLimits() {
        #expect(ImportLimits.maxCompressedBytes == 64 * 1024 * 1024)
        #expect(ImportLimits.maxPixelArea == 40_000_000)
        #expect(ImportLimits.check(pixelSize: PixelSize(width: 8000, height: 5000)) == nil)
        #expect(ImportLimits.check(pixelSize: PixelSize(width: 8000, height: 5001)) == .tooManyPixels)
        #expect(ImportLimits.check(pixelSize: PixelSize(width: 0, height: 5)) == .invalidDimensions)
    }

    @Test("Scroll limits match SPEC FR-10, and the first reached limit wins")
    func scrollLimits() {
        let limits = ScrollLimits.default
        #expect(limits.maxDuration == .seconds(120))
        #expect(limits.maxAcceptedFrames == 200)
        #expect(limits.maxOutputArea == 40_000_000)
        #expect(limits.maxSide == 32_768)
        #expect(limits.defaultMaxHeight == 20_000)
        #expect(
            limits.firstExceeded(elapsed: .seconds(5), frames: 10, outputSize: PixelSize(width: 1000, height: 1000))
                == nil)
        #expect(
            limits.firstExceeded(elapsed: .seconds(121), frames: 201, outputSize: PixelSize(width: 1, height: 1))
                == .duration)
        #expect(
            limits.firstExceeded(elapsed: .zero, frames: 201, outputSize: PixelSize(width: 1, height: 1)) == .frames)
        #expect(
            limits.firstExceeded(elapsed: .zero, frames: 1, outputSize: PixelSize(width: 1000, height: 20_001))
                == .height)
        #expect(
            limits.firstExceeded(elapsed: .zero, frames: 1, outputSize: PixelSize(width: 2000, height: 20_001)) == .area
        )
        #expect(
            limits.firstExceeded(elapsed: .zero, frames: 1, outputSize: PixelSize(width: 32_769, height: 1)) == .side)
    }

    @Test("Export filenames never include titles or text and are filesystem safe")
    func exportFilename() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let name = ExportFilename.make(for: date, format: .png, timeZone: TimeZone(identifier: "UTC")!)
        #expect(name == "Recortia 2026-09-21 at 14.13.20.png")
        #expect(!name.contains("/") && !name.contains(":"))
        let jpeg = ExportFilename.make(for: date, format: .jpeg(quality: 0.9), timeZone: TimeZone(identifier: "UTC")!)
        #expect(jpeg.hasSuffix(".jpg"))
    }

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

    @Test("Export options validate scale and JPEG quality")
    func exportOptionsValidation() {
        #expect(throws: ExportOptionsError.self) { try ExportOptions(format: .png, scale: 0).validated() }
        #expect(throws: ExportOptionsError.self) { try ExportOptions(format: .png, scale: .nan).validated() }
        #expect(throws: ExportOptionsError.self) {
            try ExportOptions(format: .jpeg(quality: 1.5), scale: 1).validated()
        }
        #expect(throws: Never.self) { try ExportOptions(format: .jpeg(quality: 0.8), scale: 2).validated() }
    }

    @Test("Capture delay is clamped to 0…10 seconds")
    func captureDelayClamp() {
        #expect(CaptureRequest.clampedDelay(-3) == 0)
        #expect(CaptureRequest.clampedDelay(4) == 4)
        #expect(CaptureRequest.clampedDelay(99) == 10)
    }
}
