import Domain
import Foundation
import MacPlatform
import Testing

@testable import Features

/// Records what the feature models report, for the hook tests.
@MainActor
final class FakeDiagnostics: DiagnosticsSink {
    private(set) var events: [DiagnosticEvent] = []
    func record(_ event: DiagnosticEvent) { events.append(event) }
}

// Failure modes (B-10): the file written while the switch is off, by default or for preferences
// saved before B-10; turning the switch off deleting the file; a permission reported again on
// every check; the capture and export outcomes not reaching the sink, or reaching it as anything
// but their typed case.
@Suite("Diagnostics recorder and hooks (B-10)")
@MainActor
struct DiagnosticsTests {
    static let versions = DiagnosticVersions(
        app: DiagnosticVersion(major: 0, minor: 19, patch: 0), build: 7,
        macOS: DiagnosticVersion(major: 26, minor: 0, patch: 0))

    @MainActor
    private final class Context {
        let root: URL
        let settings = SettingsStore(storage: MemoryPreferenceStorage())
        let clock = ManualClock()
        let log: DiagnosticsLog
        let recorder: DiagnosticsRecorder

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(
                path: "diagnostics-recorder-\(UUID().uuidString)", directoryHint: .isDirectory)
            log = DiagnosticsLog(directory: root.appending(path: "Recortia", directoryHint: .isDirectory))
            recorder = DiagnosticsRecorder(
                log: log, settings: settings, clock: clock, versions: DiagnosticsTests.versions)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func lines() throws -> [String] {
            try String(contentsOf: log.fileURL, encoding: .utf8).split(separator: "\n").map(String.init)
        }
    }

    @Test("Off by default, including for preferences saved before B-10: nothing is written")
    func offByDefault() async throws {
        #expect(!Preferences().writesDiagnosticsFile)
        var legacy = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any])
        legacy.removeValue(forKey: "writesDiagnosticsFileChoice")
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!decoded.writesDiagnosticsFile)

        let context = try Context()
        context.recorder.recordLaunch()
        context.recorder.record(.permissionStatus(permission: .screenRecording, granted: true))
        await context.recorder.flush()
        #expect(await !context.recorder.fileExists())
        #expect(!FileManager.default.fileExists(atPath: context.log.directory.path), "not even the folder")
    }

    @Test("Turned on, events become typed lines in order; turned off, writing stops and the file stays")
    func onWritesTypedLines() async throws {
        let context = try Context()
        context.recorder.setOn(true)
        #expect(context.settings.preferences.writesDiagnosticsFile)
        context.recorder.recordLaunch()
        context.recorder.record(.exportFinished(sink: .clipboard, format: .png, duration: .milliseconds(9)))
        #expect(await context.recorder.fileExists())
        let date = context.clock.now()
        #expect(
            try context.lines() == [
                DiagnosticEvent.diagnosticsTurnedOn(Self.versions).line(at: date),
                DiagnosticEvent.appLaunched(Self.versions).line(at: date),
                DiagnosticEvent.exportFinished(sink: .clipboard, format: .png, duration: .milliseconds(9))
                    .line(at: date),
            ])

        context.recorder.setOn(false)
        context.recorder.record(.qrDecodingFailed(duration: .zero))
        await context.recorder.flush()
        #expect(try context.lines().count == 3, "nothing is written once the switch is off")
        #expect(await context.recorder.fileExists(), "turning the switch off keeps the file")

        #expect(await context.recorder.delete())
        #expect(await !context.recorder.fileExists())
    }

    @Test("A permission is written when its status changes, not on every check")
    func permissionChangesOnly() async throws {
        let context = try Context()
        context.recorder.setOn(true)
        for granted in [false, false, true, true, false] {
            context.recorder.record(.permissionStatus(permission: .screenRecording, granted: granted))
        }
        context.recorder.record(.permissionStatus(permission: .accessibility, granted: false))
        await context.recorder.flush()
        let permissions = try context.lines().filter { $0.contains(" permission.status ") }
        #expect(
            permissions.map { $0.split(separator: " ").dropFirst().joined(separator: " ") } == [
                "permission.status permission=screen_recording granted=false",
                "permission.status permission=screen_recording granted=true",
                "permission.status permission=screen_recording granted=false",
                "permission.status permission=accessibility granted=false",
            ])
    }

    @Test("A permission change dropped while the writer is behind is written at the next report")
    func droppedPermissionIsNotForgotten() async throws {
        let context = try Context()
        context.recorder.setOn(true)
        // Nothing reaches the writer until this test awaits, so the queue fills.
        for _ in 0..<DiagnosticsRecorder.maxPending {
            context.recorder.record(.qrDecodingFailed(duration: .zero))
        }
        context.recorder.record(.permissionStatus(permission: .accessibility, granted: true))
        await context.recorder.flush()
        context.recorder.record(.permissionStatus(permission: .accessibility, granted: true))
        await context.recorder.flush()
        let lines = try context.lines()
        #expect(lines.count == DiagnosticsRecorder.maxPending + 1, "the queue bound drops the overflow")
        #expect(lines.last?.hasSuffix(" permission.status permission=accessibility granted=true") == true)
    }

    @Test("A capture reports its start, its typed outcome and its duration")
    func captureHooks() async {
        let h = CaptureHarness(permissionGranted: false)
        h.permission.grantOnRequest = true
        h.coordinator.start(.region)
        await waitFor("selecting") { h.coordinator.state == .selecting }
        h.clock.advance(bySeconds: 0.25)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("captured") { h.completions.count == 1 }
        let size = h.completions.first?.session.document.assets.values.first?.pixelSize
        #expect(
            h.diagnostics.events == [
                .permissionStatus(permission: .screenRecording, granted: false),
                .captureStarted(mode: .region, purpose: .edit),
                .permissionStatus(permission: .screenRecording, granted: true),
                .captureFinished(
                    mode: .region, purpose: .edit, duration: .milliseconds(250),
                    width: size?.width ?? -1, height: size?.height ?? -1),
            ])

        let failed = CaptureHarness()
        failed.capture.immediateCaptureError = .system(code: 5)
        failed.coordinator.start(.window, purpose: .recognizeText)
        failed.coordinator.commitSelection(.window(TestFixtures.window))
        await waitFor("failed") { failed.coordinator.state == .failed(.system(code: 5)) }
        #expect(
            failed.diagnostics.events.last
                == .captureFailed(mode: .window, failure: .system(code: 5), duration: .zero))

        let canceled = CaptureHarness()
        canceled.coordinator.start(.region)
        canceled.coordinator.cancel()
        #expect(canceled.diagnostics.events.last == .captureCancelled(mode: .region, duration: .zero))
    }

    @Test("An export reports its sink, format and typed failure, never the failure's file or name")
    func exportHooks() async {
        let h = ExportHarness()
        #expect(await h.export(.copy) == .copied)
        h.files.error = .accessDenied
        let folder = URL(fileURLWithPath: "/private/tmp/Secret Project")
        _ = await h.export(
            .save(to: folder.appending(path: "Quarterly.png"), format: .fixed(.jpeg(quality: 0.8)), replacing: nil))
        h.files.error = .leftover(name: "Quarterly.png.partial")
        _ = await h.export(.saveToFolder(folder))
        #expect(
            h.diagnostics.events == [
                .exportFinished(sink: .clipboard, format: .png, duration: .zero),
                .exportFailed(sink: .file, format: .jpeg, failure: .accessDenied, duration: .zero),
                .exportFailed(sink: .file, format: .png, failure: .leftover, duration: .zero),
            ])
        let lines = h.diagnostics.events.map { $0.line(at: Date()) }.joined(separator: "\n")
        for secret in ["Secret", "Quarterly", "partial", "tmp"] {
            #expect(!lines.contains(secret), "\(secret) reached a line")
        }
    }
}
