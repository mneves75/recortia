#if DEBUG
    import AppKit
    import Foundation

    /// One checked outcome inside a scenario. `detail` records the observed value so a reader can
    /// see why it passed or failed without rerunning.
    struct E2EAssertion: Codable, Equatable {
        let name: String
        let passed: Bool
        let detail: String
    }

    /// One scenario's machine-readable result (`report.json` is an array of these).
    struct E2EScenarioResult: Codable {
        let id: String
        let title: String
        let passed: Bool
        let assertions: [E2EAssertion]
        let screenshots: [String]
        let durationMs: Int
    }

    /// Thrown to end a scenario early; the reason becomes a failed assertion.
    struct E2EAbort: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    /// Collects assertions and screenshots for the scenario that is running.
    @MainActor
    final class ScenarioContext {
        let id: String
        let title: String
        let output: E2EOutput
        private(set) var assertions: [E2EAssertion] = []
        private(set) var screenshots: [String] = []

        init(id: String, title: String, output: E2EOutput) {
            self.id = id
            self.title = title
            self.output = output
        }

        var passed: Bool { !assertions.isEmpty && assertions.allSatisfy(\.passed) }

        /// Records an assertion and returns its result so callers can stop dependent checks.
        @discardableResult
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") -> Bool {
            assertions.append(E2EAssertion(name: name, passed: condition, detail: detail()))
            return condition
        }

        /// Like `check`, but ends the scenario when the condition does not hold.
        func require(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") throws {
            let text = detail()
            guard check(name, condition, text) else { throw E2EAbort("\(name) failed: \(text)") }
        }

        /// Unwraps a value the rest of the scenario depends on, recording the outcome.
        func unwrap<T>(_ name: String, _ value: T?, _ detail: @autoclosure () -> String = "") throws -> T {
            let text = detail()
            guard let value else {
                check(name, false, text.isEmpty ? "value was nil" : text)
                throw E2EAbort("\(name): value was nil")
            }
            check(name, true, text)
            return value
        }

        /// Renders `view` offscreen to `NN-<scenario>-<shot>-<lang>.png` and records the path.
        func snapshot(_ view: NSView, shot: String? = nil, background: NSColor? = .windowBackgroundColor) {
            let name = output.nextScreenshotName(scenario: shot.map { "\(id)-\($0)" } ?? id)
            do {
                let data = try E2ESnapshot.png(of: view, background: background)
                try data.write(to: output.directory.appending(path: name), options: .atomic)
                screenshots.append(name)
                check("screenshot \(name)", true, "\(Int(view.bounds.width))×\(Int(view.bounds.height)) pt at 2×")
            } catch {
                check("screenshot \(name)", false, "\(error)")
            }
        }

        /// Like `snapshot`, but draws the view over `underlay` (see `E2ESnapshot.png(of:over:)`).
        func snapshot(_ view: NSView, shot: String, over underlay: CGImage) {
            let name = output.nextScreenshotName(scenario: "\(id)-\(shot)")
            do {
                let data = try E2ESnapshot.png(of: view, over: underlay)
                try data.write(to: output.directory.appending(path: name), options: .atomic)
                screenshots.append(name)
                check("screenshot \(name)", true, "\(Int(view.bounds.width))×\(Int(view.bounds.height)) pt at 2×")
            } catch {
                check("screenshot \(name)", false, "\(error)")
            }
        }

        func result(durationMs: Int) -> E2EScenarioResult {
            E2EScenarioResult(
                id: id, title: title, passed: passed, assertions: assertions, screenshots: screenshots,
                durationMs: durationMs)
        }
    }

    /// The run's output directory and deterministic screenshot numbering.
    @MainActor
    final class E2EOutput {
        let directory: URL
        let language: String
        private var counter = 0

        init(directory: URL, language: String) {
            self.directory = directory
            self.language = language
        }

        /// A private scratch folder for files the scenarios write (exports, fixtures).
        var workDirectory: URL { directory.appending(path: "work", directoryHint: .isDirectory) }

        func nextScreenshotName(scenario: String) -> String {
            counter += 1
            return String(format: "%02d-", counter) + "\(scenario)-\(language).png"
        }

        func write(_ results: [E2EScenarioResult]) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(results).write(to: directory.appending(path: "report.json"), options: .atomic)
            try Data(markdown(results).utf8).write(to: directory.appending(path: "report.md"), options: .atomic)
        }

        private func markdown(_ results: [E2EScenarioResult]) -> String {
            let passed = results.filter(\.passed).count
            var lines = [
                "# Recortia E2E report (\(language))", "",
                "\(passed) of \(results.count) scenarios passed.", "",
                "| # | Scenario | Result | Assertions | Screenshots | ms |",
                "|---|---|---|---|---|---|",
            ]
            for (index, result) in results.enumerated() {
                let ok = result.assertions.filter(\.passed).count
                let shots = result.screenshots.map { "[\($0)](\($0))" }.joined(separator: "<br>")
                lines.append(
                    "| \(index + 1) | \(result.title) (`\(result.id)`) | \(result.passed ? "pass" : "**FAIL**") | "
                        + "\(ok)/\(result.assertions.count) | \(shots) | \(result.durationMs) |")
            }
            let failures = results.flatMap { result in
                result.assertions.filter { !$0.passed }.map { "- `\(result.id)`: \($0.name): \($0.detail)" }
            }
            if !failures.isEmpty {
                lines += ["", "## Failed assertions", ""] + failures
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }
#endif
