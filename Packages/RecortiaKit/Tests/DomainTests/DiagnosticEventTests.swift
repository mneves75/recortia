import Foundation
import Testing

@testable import Domain

// Failure modes (B-10, SPEC §7): a line that is not ISO-8601 time, event name and key=value pairs;
// an event whose name is not in the allowlist the E2E scenario checks; a value that is not a
// lowercase token, a number or a version.
@Suite("Diagnostic event lines (B-10)")
struct DiagnosticEventTests {
    static let versions = DiagnosticVersions(
        app: DiagnosticVersion(major: 0, minor: 19, patch: 0), build: 42,
        macOS: DiagnosticVersion(major: 26, minor: 1, patch: 0))

    /// One value of every case; `everyCaseIsSampled` fails when a case is added without one.
    static let samples: [DiagnosticEvent] = [
        .appLaunched(versions), .diagnosticsTurnedOn(versions),
        .captureStarted(mode: .repeatRegion, purpose: .recognizeText),
        .captureFinished(mode: .region, purpose: .edit, duration: .milliseconds(412), width: 1280, height: 800),
        .captureCancelled(mode: .window, duration: .milliseconds(30)),
        .captureFailed(mode: .display, failure: .system(code: -1), duration: .seconds(1)),
        .exportFinished(sink: .clipboard, format: .png, duration: .milliseconds(5)),
        .exportFailed(sink: .github, format: .automatic, failure: .upload(.rateLimited), duration: .zero),
        .exportCancelled(sink: .drag, format: .jpeg, duration: .milliseconds(2)),
        .permissionStatus(permission: .screenRecording, granted: false),
        .textRecognitionFinished(lines: 7, duration: .milliseconds(800)),
        .textRecognitionFailed(duration: .milliseconds(10)),
        .qrDecodingFinished(codes: 1, duration: .milliseconds(20)),
        .qrDecodingFailed(duration: .milliseconds(3)),
        .scrollCaptureFinished(frames: 12, automatic: true, partial: false, duration: .seconds(9)),
        .scrollCaptureFailed(failure: .noFrames, frames: 0),
        .autoMaskingFinished(regions: 3, outcome: .timedOut, duration: .milliseconds(2500)),
    ]

    /// Time, name, then key=value pairs whose values are lowercase tokens, integers or versions.
    static let linePattern =
        #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z [a-z_]+(\.[a-z_]+)+( [a-z_]+=(-?[0-9]+(\.[0-9]+)*|[a-z_]+))*$"#

    @Test("Every case has a sample and a name from the allowlist")
    func everyCaseIsSampled() {
        #expect(Set(Self.samples.map(\.name)) == DiagnosticEvent.names)
        #expect(Self.samples.count == DiagnosticEvent.names.count)
    }

    @Test("A line is ISO-8601 time, the event name and key=value pairs")
    func lineShape() throws {
        let date = Date(timeIntervalSince1970: 1_795_000_000.25)
        for event in Self.samples {
            let line = event.line(at: date)
            #expect(line.range(of: Self.linePattern, options: .regularExpression) != nil, "\(line)")
            #expect(line.hasPrefix("2026-11-18T"), "\(line)")
            #expect(!line.contains("\n"))
        }
        let finished = DiagnosticEvent.captureFinished(
            mode: .region, purpose: .edit, duration: .milliseconds(412), width: 1280, height: 800)
        #expect(
            finished.line(at: date)
                == "2026-11-18T11:06:40.250Z capture.finished mode=region purpose=edit duration_ms=412 width=1280 height=800"
        )
        #expect(
            DiagnosticEvent.appLaunched(Self.versions).line(at: date)
                == "2026-11-18T11:06:40.250Z app.launched app=0.19.0 build=42 macos=26.1.0")
        #expect(
            DiagnosticEvent.exportFailed(sink: .file, format: .png, failure: .system(code: -36), duration: .zero)
                .line(at: date)
                == "2026-11-18T11:06:40.250Z export.failed sink=file format=png failure=system code=-36 duration_ms=0")
    }

    @Test("Versions read only their leading numbers")
    func versionParsing() {
        #expect(DiagnosticVersion(parsing: "0.19.0") == DiagnosticVersion(major: 0, minor: 19, patch: 0))
        #expect(DiagnosticVersion(parsing: "26.1") == DiagnosticVersion(major: 26, minor: 1, patch: 0))
        #expect(DiagnosticVersion(parsing: "1.2.3-beta4") == DiagnosticVersion(major: 1, minor: 2, patch: 0))
        #expect(DiagnosticVersion(parsing: "") == DiagnosticVersion(major: 0, minor: 0, patch: 0))
        #expect(DiagnosticVersion(parsing: String(repeating: "9", count: 400)).major == 0)
    }
}
