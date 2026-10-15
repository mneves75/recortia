#if DEBUG
    import Domain
    import Features
    import Foundation
    import MacPlatform

    /// Exercises the production adapter without querying desktop content or posting native events.
    @MainActor
    enum AutoScrollRegression {
        struct Check {
            let name: String
            let passed: Bool
        }

        static func run() async -> [Check] {
            var checks: [Check] = []
            func check(_ name: String, _ passed: Bool) {
                checks.append(Check(name: name, passed: passed))
            }

            for change in ["other application", "same process", "missing binding", "superseded session", "stop"] {
                let fixture = Fixture()
                let adapter = fixture.adapter()
                let step = Task { await adapter.step(fixture.target) }
                await fixture.waitForDiscovery()
                switch change {
                case "other application": fixture.frontmostID = fixture.otherApp.id
                case "same process": fixture.frontmostID = fixture.samePID.id
                case "missing binding": fixture.binding = nil
                case "superseded session":
                    fixture.binding = ScrollWindowBinding(sessionID: UUID(), windowID: fixture.bound.id)
                default: adapter.stop()
                }
                fixture.releaseDiscovery()
                let result = await step.value
                check("\(change) during discovery returns targetLost", result == .targetLost)
                check("\(change) during discovery creates no scroller", fixture.created.isEmpty)
                check("\(change) during discovery posts zero events", fixture.events.isEmpty)
                adapter.stop()
            }

            let missing = Fixture()
            missing.binding = nil
            let missingAdapter = missing.adapter(suspend: false)
            check(
                "missing initial binding returns targetLost", await missingAdapter.step(missing.target) == .targetLost)
            check("missing initial binding creates no scroller", missing.created.isEmpty)
            check("missing initial binding posts zero events", missing.events.isEmpty)
            missingAdapter.stop()

            let accepted = Fixture()
            let adapter = accepted.adapter(suspend: false)
            check("bound window accepts a scroll step", await adapter.step(accepted.target) == .scrolled)
            check("only the bound window receives the event", accepted.events == [accepted.bound.id])
            check("only the bound window gets a scroller", accepted.created == [accepted.bound.id])
            accepted.frontmostID = accepted.samePID.id
            check(
                "same-PID window change refuses a cached scroller", await adapter.step(accepted.target) == .targetLost)
            check("cached scroller posts no event after window change", accepted.events == [accepted.bound.id])
            adapter.stop()

            let chosen = Fixture()
            let chosenAdapter = chosen.adapter(suspend: false)
            check(
                "a chosen window different from the binding is refused",
                await chosenAdapter.step(.window(chosen.samePID)) == .targetLost)
            check("a different chosen window posts zero events", chosen.events.isEmpty)
            chosenAdapter.stop()
            return checks
        }

        private final class Fixture {
            let display = DisplayInfo(
                id: 1, frame: Rect(x: 0, y: 0, width: 800, height: 600),
                pointPixelScale: 1, fingerprint: "synthetic-scroll-display")
            let bound = WindowInfo(
                id: 11, ownerName: "A", ownerPID: 101, title: nil,
                frame: Rect(x: 0, y: 0, width: 800, height: 600), displayID: 1)
            let samePID = WindowInfo(
                id: 12, ownerName: "A", ownerPID: 101, title: nil,
                frame: Rect(x: 0, y: 0, width: 800, height: 600), displayID: 1)
            let otherApp = WindowInfo(
                id: 21, ownerName: "B", ownerPID: 202, title: nil,
                frame: Rect(x: 0, y: 0, width: 800, height: 600), displayID: 1)
            var binding: ScrollWindowBinding? = ScrollWindowBinding(sessionID: UUID(), windowID: 11)
            var frontmostID: UInt32? = 11
            var events: [UInt32] = []
            var created: [UInt32] = []
            private var discovery: CheckedContinuation<Void, Never>?
            private var arrival: CheckedContinuation<Void, Never>?
            private var isDiscovering = false

            var target: CaptureTarget { .region(Rect(x: 0, y: 0, width: 400, height: 300), display: display) }

            func adapter(suspend: Bool = true) -> LiveAutoScroll {
                LiveAutoScroll(
                    binding: { self.binding },
                    windows: {
                        if suspend {
                            await withCheckedContinuation { continuation in
                                self.discovery = continuation
                                self.isDiscovering = true
                                self.arrival?.resume()
                                self.arrival = nil
                            }
                        }
                        return [self.bound, self.samePID, self.otherApp]
                    }, frontmost: { _ in self.frontmostID },
                    makeDriver: { window, _, _ in
                        self.created.append(window.id)
                        return RecordingDriver(windowID: window.id, post: { self.events.append($0) })
                    })
            }

            func waitForDiscovery() async {
                if isDiscovering { return }
                await withCheckedContinuation { arrival = $0 }
            }

            func releaseDiscovery() {
                discovery?.resume()
                discovery = nil
            }
        }

        private final class RecordingDriver: AutoScrollDriving {
            let windowID: UInt32
            let post: (UInt32) -> Void
            private var running = false

            init(windowID: UInt32, post: @escaping (UInt32) -> Void) {
                self.windowID = windowID
                self.post = post
            }

            func start() throws(AutoScrollError) { running = true }
            func stop(reason: AutoScrollStopReason) { running = false }
            func scrollDown(byPixels pixels: Int) -> AutoScrollStepResult {
                guard running else { return .notRunning }
                post(windowID)
                return .scrolled
            }
        }
    }
#endif
