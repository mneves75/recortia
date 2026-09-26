#if DEBUG
    import AppKit
    import Foundation

    /// One end-to-end scenario: drives the real models and windows, asserts concrete outcomes,
    /// and saves screenshots.
    struct E2EScenario {
        let id: String
        let title: String
        let run: @MainActor (E2EHarness, ScenarioContext) async throws -> Void
    }

    /// Entry point for `-RecortiaE2E <absolute output dir> [-RecortiaE2EOnly id,id]`. DEBUG builds
    /// only; Release builds contain none of this code.
    @MainActor
    enum E2ERunner {
        static let argument = "-RecortiaE2E"
        static let onlyArgument = "-RecortiaE2EOnly"

        /// Starts the runner when the launch argument is present. Returns false otherwise.
        static func startIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            if E2EPanelProbe.runIfRequested(arguments: arguments) { return true }
            guard let index = arguments.firstIndex(of: argument) else { return false }
            guard index + 1 < arguments.count, arguments[index + 1].hasPrefix("/") else {
                log("usage: Recortia \(argument) <absolute output dir> [\(onlyArgument) id,id]")
                exit(2)
            }
            let directory = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
            var only: [String]?
            if let flag = arguments.firstIndex(of: onlyArgument), flag + 1 < arguments.count {
                only = arguments[flag + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            Task {
                let code = await run(directory: directory, only: only)
                exit(code)
            }
            return true
        }

        static func run(directory: URL, only: [String]?) async -> Int32 {
            NSApp.appearance = NSAppearance(named: .aqua)
            let language = Bundle.main.preferredLocalizations.first ?? "en"
            let output = E2EOutput(directory: directory, language: language)
            let scenarios = E2EScenarios.all
            if let only {
                let known = Set(scenarios.map(\.id))
                let unknown = only.filter { !known.contains($0) }
                guard unknown.isEmpty else {
                    log("unknown scenario ids: \(unknown.joined(separator: ", ")); known: \(scenarios.map(\.id))")
                    return 2
                }
            }
            let selected = scenarios.filter { only?.contains($0.id) ?? true }
            let harness: E2EHarness
            do {
                try FileManager.default.createDirectory(at: output.workDirectory, withIntermediateDirectories: true)
                harness = try E2EHarness(output: output)
            } catch {
                log("setup failed: \(error)")
                return 1
            }
            log("running \(selected.count) scenarios (\(language)) into \(directory.path(percentEncoded: false))")

            var results: [E2EScenarioResult] = []
            for scenario in selected {
                let context = ScenarioContext(id: scenario.id, title: scenario.title, output: output)
                let started = ContinuousClock.now
                do {
                    try await scenario.run(harness, context)
                } catch {
                    context.check("scenario ran to completion", false, "\(error)")
                }
                harness.reset()
                let elapsed = ContinuousClock.now - started
                let milliseconds = Int(
                    elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
                let result = context.result(durationMs: milliseconds)
                results.append(result)
                let failed = result.assertions.filter { !$0.passed }
                log("\(result.passed ? "PASS" : "FAIL") \(scenario.id) (\(milliseconds) ms)")
                for assertion in failed { log("    ✗ \(assertion.name): \(assertion.detail)") }
            }
            harness.tearDown()

            do {
                try output.write(results)
            } catch {
                log("could not write the report: \(error)")
                return 1
            }
            let passed = results.filter(\.passed).count
            log("\(passed)/\(results.count) scenarios passed")
            return !results.isEmpty && passed == results.count ? 0 : 1
        }

        static func log(_ message: String) {
            FileHandle.standardError.write(Data("[e2e] \(message)\n".utf8))
        }
    }
#endif
