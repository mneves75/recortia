#if DEBUG
    import AppKit
    import Foundation

    /// One end-to-end scenario: drives the real models and windows, asserts concrete outcomes,
    /// and saves screenshots.
    struct E2EScenario {
        let id: String
        let title: String
        let run: @MainActor (E2EHarness, ScenarioContext) async throws -> Void
        /// Measurements outside the gate run only when `-RecortiaE2EOnly` names them.
        var runsOnlyWhenNamed = false
    }

    /// One admitted launch of the E2E binary: the scenario runner or one of its child probes.
    enum E2ELaunchRequest {
        case runner(directory: URL, only: [String]?)
        case panelProbe(E2EPanelProbe.Kind)
        case lastWindowProbe(LastWindowProbe.Kind)

        struct Refusal: Error {
            let reason: String
        }

        @MainActor
        static func parse(_ arguments: [String]) -> Result<E2ELaunchRequest, Refusal> {
            func value(after flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
                return arguments[index + 1]
            }
            // One mode, and each launch flag at most once; system arguments such as
            // -AppleLanguages pass through untouched.
            let flags = [E2ERunner.argument, E2ERunner.onlyArgument, E2EPanelProbe.argument, LastWindowProbe.argument]
            if let repeated = flags.first(where: { flag in arguments.filter { $0 == flag }.count > 1 }) {
                return .failure(Refusal(reason: "\(repeated) appears more than once"))
            }
            let modes = [E2ERunner.argument, E2EPanelProbe.argument, LastWindowProbe.argument].filter(
                arguments.contains)
            guard modes.count <= 1 else { return .failure(Refusal(reason: "more than one launch mode: \(modes)")) }
            if modes.first != E2ERunner.argument, arguments.contains(E2ERunner.onlyArgument) {
                return .failure(Refusal(reason: "\(E2ERunner.onlyArgument) needs \(E2ERunner.argument)"))
            }
            if arguments.contains(E2EPanelProbe.argument) {
                guard let kind = value(after: E2EPanelProbe.argument).flatMap(E2EPanelProbe.Kind.init(rawValue:))
                else {
                    return .failure(
                        Refusal(reason: "known panel probes: \(E2EPanelProbe.Kind.allCases.map(\.rawValue))"))
                }
                return .success(.panelProbe(kind))
            }
            if arguments.contains(LastWindowProbe.argument) {
                guard let kind = value(after: LastWindowProbe.argument).flatMap(LastWindowProbe.Kind.init(rawValue:))
                else {
                    return .failure(
                        Refusal(reason: "known last-window probes: \(LastWindowProbe.Kind.allCases.map(\.rawValue))"))
                }
                return .success(.lastWindowProbe(kind))
            }
            guard arguments.contains(E2ERunner.argument) else { return .failure(Refusal(reason: "no runner request")) }
            guard let path = value(after: E2ERunner.argument), path.hasPrefix("/") else {
                return .failure(Refusal(reason: "the output directory must be an absolute path"))
            }
            var only: [String]?
            if arguments.contains(E2ERunner.onlyArgument) {
                guard let list = value(after: E2ERunner.onlyArgument) else {
                    return .failure(Refusal(reason: "\(E2ERunner.onlyArgument) needs scenario ids"))
                }
                let ids = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let known = Set(E2EScenarios.all.map(\.id))
                let unknown = ids.filter { !known.contains($0) }
                guard !ids.isEmpty, unknown.isEmpty else {
                    return .failure(Refusal(reason: "unknown scenario ids \(unknown); known: \(known.sorted())"))
                }
                only = ids
            }
            return .success(.runner(directory: URL(filePath: path, directoryHint: .isDirectory), only: only))
        }
    }

    /// Entry point for `-RecortiaE2E <absolute output dir> [-RecortiaE2EOnly id,id]`. DEBUG builds
    /// only; Release builds contain none of this code.
    @MainActor
    enum E2ERunner {
        static let argument = "-RecortiaE2E"
        /// Where `AppDelegate` hands files the system asked to open: the runner's own model.
        static var openFiles: (@MainActor ([URL]) -> Void)?
        static let onlyArgument = "-RecortiaE2EOnly"

        /// Parses and validates this process's whole launch request, before the app model exists
        /// (R3-D01). A missing or malformed request (opened from Finder, a relative directory, an
        /// unknown scenario or probe kind) prints one line and exits 2: without the runner, the E2E
        /// binary would otherwise build the live composition root.
        static func admit(arguments: [String] = ProcessInfo.processInfo.arguments) -> E2ELaunchRequest {
            switch E2ELaunchRequest.parse(arguments) {
            case .success(let request):
                return request
            case .failure(let refusal):
                log(
                    "RecortiaE2E refuses this launch (\(refusal.reason)); scripts/e2e.sh launches it with "
                        + "\(argument) <absolute output dir> [\(onlyArgument) id,id]")
                exit(2)
            }
        }

        /// The SwiftUI scene and its commands use the same synthetic app as the scenarios.
        static func prepare(_ request: E2ELaunchRequest) -> E2EHarness? {
            guard case .runner(let directory, _) = request else { return nil }
            let language = Bundle.main.preferredLocalizations.first ?? "en"
            do {
                return try E2EHarness(output: E2EOutput(directory: directory, language: language))
            } catch {
                log("setup failed: \(error)")
                exit(1)
            }
        }

        /// Starts what `admit` accepted; the process exits with its result.
        static func start(_ request: E2ELaunchRequest, harness: E2EHarness?) {
            switch request {
            case .panelProbe(let kind): E2EPanelProbe.start(kind)
            case .lastWindowProbe(let kind): LastWindowProbe.start(kind)
            case .runner(_, let only):
                guard let harness else {
                    log("setup failed: missing scenario harness")
                    exit(1)
                }
                Task {
                    let code = await run(harness, only: only)
                    exit(code)
                }
            }
        }

        private static func run(_ harness: E2EHarness, only: [String]?) async -> Int32 {
            NSApp.appearance = NSAppearance(named: .aqua)
            openFiles = { [weak app = harness.app] in app?.openFiles($0) }
            let output = harness.output
            let scenarios = E2EScenarios.all
            let selected = scenarios.filter { only?.contains($0.id) ?? !$0.runsOnlyWhenNamed }
            log(
                "running \(selected.count) scenarios (\(output.language)) into \(output.directory.path(percentEncoded: false))"
            )

            var results: [E2EScenarioResult] = []
            for scenario in selected {
                let context = ScenarioContext(id: scenario.id, title: scenario.title, output: output)
                let started = ContinuousClock.now
                // Liveness, not progress: the run watchdog stops a run after silence, so a scenario
                // that legitimately takes minutes must be visible as alive from its first moment.
                log("START \(scenario.id)")
                do {
                    try await scenario.run(harness, context)
                } catch {
                    context.check("scenario ran to completion", false, "\(error)")
                }
                harness.reset()
                if scenario.id == "region-overlay" {
                    log("capture-focus predecessor reset at uptime=\(ProcessInfo.processInfo.systemUptime)")
                }
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
