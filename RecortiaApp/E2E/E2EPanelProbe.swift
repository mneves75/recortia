#if DEBUG
    import AppKit
    import Features
    import Imaging
    import SwiftUI

    /// Hosts a real view in the real panel class the way the app's presenter does, in a child
    /// process of this binary, so an AppKit exception or layout recursion (which ends the process)
    /// becomes a failed assertion instead of a crashed run. The panel is parked far offscreen, fully
    /// transparent, and ignores the mouse; see `host` for when it is ordered front.
    @MainActor
    enum E2EPanelProbe {
        enum Kind: String, CaseIterable {
            /// `CaptureUIController.showCountdown`: `HostingPanel` hosting the countdown.
            case countdown = "countdown-panel"
            /// `PinsUIController.render`: `PinPanel` hosting a pinned capture.
            case pin = "pin-panel"
            /// The same pin with Keep on Top and click-through on, ordered in: AppPresence must still
            /// count it, so Recortia stays regular (ADR-007 amendment).
            case pinOnTop = "pin-on-top-panel"

            var assertion: String {
                switch self {
                case .countdown, .pin: "the real panel hosts its content without an AppKit exception or layout loop"
                case .pinOnTop: "a shown floating, click-through pin is a switchable window and keeps Recortia regular"
                }
            }
        }

        static let argument = "-RecortiaE2EProbe"
        static let settleTime: Duration = .milliseconds(1_500)

        /// Parent side: runs the probe and records whether the child survived.
        static func check(_ kind: Kind, _ context: ScenarioContext) async {
            let logURL = context.output.workDirectory.appending(path: "probe-\(kind.rawValue).log")
            let process = Process()
            process.executableURL = Bundle.main.executableURL
            process.arguments = [argument, kind.rawValue, "-AppleLanguages", "(\(context.output.language))"]
            do {
                FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
                let log = try FileHandle(forWritingTo: logURL)
                process.standardOutput = log
                process.standardError = log
                try process.run()
            } catch {
                context.check("\(kind.rawValue) probe starts", false, "\(error)")
                return
            }
            let finished = await E2EWait.until(timeout: .seconds(30), poll: .milliseconds(50)) { !process.isRunning }
            if !finished { process.terminate() }
            let survived = finished && process.terminationReason == .exit && process.terminationStatus == 0
            let how = process.terminationReason == .exit ? "exited" : "killed by signal"
            context.check(
                "\(kind.rawValue): \(kind.assertion)", survived,
                finished
                    ? "child \(how) \(process.terminationStatus); log work/\(logURL.lastPathComponent)"
                    : "child timed out")
        }

        /// Child side: hosts `kind`, then exits with the result.
        static func start(_ kind: Kind) {
            Task {
                do {
                    let size = try await host(kind)
                    E2ERunner.log("probe \(kind.rawValue) survived; panel \(Int(size.width))×\(Int(size.height))")
                    exit(0)
                } catch {
                    E2ERunner.log("probe \(kind.rawValue) could not start: \(error)")
                    exit(3)
                }
            }
        }

        private static func host(_ kind: Kind) async throws -> NSSize {
            NSApp.appearance = NSAppearance(named: .aqua)
            let panel: NSPanel
            var retained: PinsModel?
            switch kind {
            case .countdown:
                let hosting = HostingPanel(title: String(localized: "Delayed Capture"), activating: false)
                hosting.setContent(CountdownView(remaining: 3, onCancel: {}), fixedToFittingSize: true)
                panel = hosting
            case .pin:
                let (pin, pins) = try makePinPanel()
                panel = pin
                retained = pins
            case .pinOnTop:
                let (pin, pins) = try makePinPanel()
                guard let id = pins.pins.first?.id else { throw E2EAbort("the probe pin is missing") }
                pins.setKeepsOnTop(true, for: id)
                pins.setClickThrough(true, for: id)
                try? await Task.sleep(for: .milliseconds(200))
                guard pin.level == .floating, pin.ignoresMouseEvents else {
                    throw E2EAbort("the pin did not follow its state: level \(pin.level.rawValue)")
                }
                panel = pin
                retained = pins
            }
            E2ESnapshot.park(panel)
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            // Ordering front matches the app, but AppKit pulls a titled panel back toward a display,
            // so only the borderless pin panel is ordered; the titled countdown panel reproduces
            // its failure without it.
            if !panel.styleMask.contains(.titled) {
                panel.orderFrontRegardless()
                guard panel.frame.maxX < -10_000, panel.frame.maxY < -10_000 else {
                    panel.orderOut(nil)
                    throw E2EAbort("the ordered panel left its offscreen position: \(panel.frame)")
                }
            }
            if kind == .pinOnTop { try await checkPresence(of: panel) }
            try? await Task.sleep(for: settleTime)
            panel.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(200))
            let size = panel.frame.size
            E2ERunner.log("probe \(kind.rawValue) frame \(panel.frame), ordered \(panel.isVisible)")
            panel.orderOut(nil)
            _ = retained
            return size
        }

        /// Ordered in as `PinPanel.presentNearPointer` does (regular first), the floating pin is the
        /// only window: a coalesced refresh that did not count it would demote Recortia.
        private static func checkPresence(of pin: NSPanel) async throws {
            let presence = AppPresence.shared
            presence.windowWillAppear()
            guard pin.isVisible, AppPresence.isSwitchable(pin) else {
                throw E2EAbort("the shown floating pin is not a switchable window")
            }
            presence.setNeedsRefresh()
            try? await Task.sleep(for: .milliseconds(500))
            guard NSApp.activationPolicy() == .regular else {
                throw E2EAbort("Recortia left regular while only a floating pin was shown")
            }
            E2ERunner.log("probe pin-on-top-panel: switchable and regular at level \(pin.level.rawValue)")
        }

        /// The real pin panel over a synthetic capture, with the model the caller must retain.
        static func makePinPanel() throws -> (PinPanel, PinsModel) {
            let settings = SettingsStore.e2eInMemory()
            let services = AppServices.live(settings: settings)
            let export = ExportCoordinator(
                exporter: services.exporter, clipboard: services.clipboard, files: services.files,
                drag: services.drag, printer: services.printer, folders: services.folders, clock: services.clock,
                settings: settings)
            let pins = PinsModel(renderer: services.renderer, settings: settings, export: export)
            let notes = SyntheticDesktop.notesWindow
            guard
                let image = try SyntheticDesktop.image().cropping(
                    to: CGRect(x: notes.minX * 2, y: notes.minY * 2, width: notes.width * 2, height: notes.height * 2))
            else { throw E2EAbort("pin image crop failed") }
            let id = try pins.add(image, source: nil, displayScale: 2)
            return (PinPanel(pinID: id, model: pins), pins)
        }
    }
#endif
