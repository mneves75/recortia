#if DEBUG
    import AppKit
    import Domain
    import Features
    import SwiftUI

    /// PERF-02: each window Recortia opens is constructed, ordered and drawn for the first time in
    /// under 50 ms (median of five fresh samples). Windows are ordered transparent and ignore the
    /// mouse, as `editor-presentation` does, so no pixels reach the user's screen. The build host is
    /// a seed OS: this is a regression budget, not PERF-01 hardware qualification. It runs only when
    /// named (`scripts/e2e.sh --only window-latency`): the editor and a first Settings open do not
    /// meet the budget yet (BACKLOG FP-028), and a failing measurement must not hide in the gate.
    @MainActor
    enum LatencyScenarios {
        static let budgetMs = 50.0
        static let samples = 5

        static func windowLatency(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            harness.reset()
            var medians: [String: Double] = [:]
            var all: [String: [Double]] = [:]

            func record(_ name: String, _ values: [Double]) {
                let median = values.sorted()[values.count / 2]
                medians[name] = median
                all[name] = values
                let detail = "median \(format(median)) ms; samples " + values.map(format).joined(separator: ", ")
                context.check("\(name): first frame in under \(Int(budgetMs)) ms", median < budgetMs, detail)
            }

            // Editor: from a decoded document to its window's first drawn frame. Each sample uses
            // a fresh import, so closing a sample's window releases only its own pixels.
            var editor: [Double] = []
            for index in 0..<samples {
                let session = try await importedSession(harness, name: "latency-\(index).png")
                let (ms, window) = measure {
                    EditorWindowController(model: EditorModel(session: session, environment: harness.environment))
                        .window
                }
                editor.append(ms)
                window?.close()
            }
            record("the editor", editor)

            // Settings: the first open builds the window; later opens reuse it
            // (`SettingsWindowController`), which is what users usually see.
            var settings: [Double] = []
            for _ in 0..<samples {
                let (ms, window) = measure { SettingsWindowController.makeWindow(model: harness.app) }
                settings.append(ms)
                window?.close()
            }
            record("Settings, first open", settings)
            let reused = SettingsWindowController.makeWindow(model: harness.app)
            var reopened: [Double] = []
            for _ in 0..<samples {
                let (ms, _) = measure { reused }
                reopened.append(ms)
                reused.orderOut(nil)
            }
            reused.close()
            record("Settings, reopened", reopened)

            var onboarding: [Double] = []
            for _ in 0..<samples {
                let (ms, window) = measure {
                    OnboardingWindowController.makeWindow(
                        NSHostingController(
                            rootView: OnboardingView(
                                onboarding: harness.app.onboarding, shortcutStatus: harness.app.shortcutStatus,
                                onClose: {})))
                }
                onboarding.append(ms)
                window?.close()
            }
            record("onboarding", onboarding)

            var pin: [Double] = []
            for _ in 0..<samples {
                let pinID = try harness.features.pins.add(harness.desktop, source: nil, displayScale: 2)
                do {
                    let (ms, window) = measure { PinPanel(pinID: pinID, model: harness.features.pins) }
                    pin.append(ms)
                    // Released before its pin closes, as `PinsUIController` does.
                    window?.close()
                }
                harness.features.pins.close(pinID)
            }
            record("a pin", pin)

            let report = ["budgetMs": [budgetMs], "samples": [Double(samples)]].merging(all) { a, _ in a }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: context.output.workDirectory.appending(path: "window-latency.json"))
            E2ERunner.log("window latency medians (ms): \(medians.mapValues(format))")
            harness.reset()
        }

        /// Constructs a window, orders it transparent and click-through, and forces its first draw.
        private static func measure(_ make: () -> NSWindow?) -> (Double, NSWindow?) {
            let start = ContinuousClock.now
            let window = make()
            if let window {
                window.alphaValue = 0
                window.ignoresMouseEvents = true
                window.orderFrontRegardless()
                window.displayIfNeeded()
            }
            let elapsed = start.duration(to: .now)
            let ms =
                Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            return (ms, window)
        }

        /// Imports `harness.desktop` through the real input and decode path without opening an editor.
        private static func importedSession(_ harness: E2EHarness, name: String) async throws -> DocumentSession {
            let url = harness.output.workDirectory.appending(path: name)
            try E2EDrawing.png(harness.desktop).write(to: url, options: .atomic)
            let importer = harness.features.importer
            let opener = importer.onImported
            var imported: DocumentSession?
            importer.onImported = { imported = $0 }
            defer { importer.onImported = opener }
            if case .failure(let failure) = await importer.importImage(from: .file(url)) {
                throw E2EAbort("import of \(name) failed: \(failure)")
            }
            guard let imported else { throw E2EAbort("import of \(name) produced no document") }
            return imported
        }

        private static func format(_ ms: Double) -> String { String(format: "%.1f", ms) }
    }
#endif
