#if DEBUG
    import AppKit
    import Foundation

    /// An owned second process supplies a foreground window without inspecting another app.
    @MainActor
    final class E2EForegroundFixture {
        private let application: NSRunningApplication
        private let directory: URL
        private let session: String
        private var sequence = 0

        var processIdentifier: pid_t { application.processIdentifier }

        private init(application: NSRunningApplication, directory: URL, session: String) {
            self.application = application
            self.directory = directory
            self.session = session
        }

        static func start(_ context: ScenarioContext) async throws -> E2EForegroundFixture {
            let session = UUID().uuidString
            let directory = context.output.workDirectory.appending(
                path: "foreground-\(session)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = true
            configuration.arguments = [
                E2EForegroundState.argument, directory.path(percentEncoded: false),
                String(ProcessInfo.processInfo.processIdentifier),
                session,
            ]
            let application: NSRunningApplication
            do {
                application = try await NSWorkspace.shared.openApplication(
                    at: Bundle.main.bundleURL.deletingLastPathComponent().appending(
                        path: "RecortiaE2EForegroundHost.app"),
                    configuration: configuration)
            } catch {
                throw E2EAbort("owned foreground fixture launch failed: \(error)")
            }
            let fixture = E2EForegroundFixture(application: application, directory: directory, session: session)
            do {
                _ = try await fixture.wait(sequence: 0, requireReady: true)
                return fixture
            } catch {
                fixture.requestStop()
                throw error
            }
        }

        func cover(_ frame: NSRect) async throws {
            guard E2EForegroundState.valid(frame) else {
                throw E2EAbort("owned foreground fixture received an invalid cover frame")
            }
            let padded = frame.insetBy(dx: -32, dy: -32)
            try await restore()
            let state = try await request("cover", frame: padded, requireReady: true)
            guard state.frame.contains(padded) else {
                throw E2EAbort("owned foreground fixture frame \(state.frame) does not contain requested \(padded)")
            }
        }

        func restore() async throws {
            if NSApp.isActive { NSApp.yieldActivation(to: application) }
            _ = try await request("activate", requireReady: true)
        }

        /// The separate positive control may request cooperation; this never activates the runner.
        func yieldToRunner() async throws {
            _ = try await request("yield", requireReady: false)
        }

        func requestStop() {
            if !application.isTerminated { application.terminate() }
        }

        func stop(_ context: ScenarioContext) async {
            requestStop()
            let terminated = await E2EWait.until(timeout: .seconds(5)) { application.isTerminated }
            context.check("owned foreground fixture terminated", terminated, "pid=\(processIdentifier)")
        }

        private func request(_ command: String, frame: CGRect? = nil, requireReady: Bool) async throws
            -> E2EForegroundState
        {
            guard !application.isTerminated else { throw E2EAbort("owned foreground fixture exited before \(command)") }
            sequence += 1
            var info: [String: Any] = [
                "command": command, "sequence": sequence, "parentPID": ProcessInfo.processInfo.processIdentifier,
            ]
            if let frame {
                info["x"] = Double(frame.minX)
                info["y"] = Double(frame.minY)
                info["width"] = Double(frame.width)
                info["height"] = Double(frame.height)
            }
            DistributedNotificationCenter.default().postNotificationName(
                E2EForegroundState.requestName(session), object: session, userInfo: info, deliverImmediately: true)
            return try await wait(sequence: sequence, requireReady: requireReady)
        }

        private func wait(sequence: Int, requireReady: Bool) async throws -> E2EForegroundState {
            let deadline = ContinuousClock.now + .seconds(8)
            var observed: E2EForegroundState?
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard !application.isTerminated else {
                    throw E2EAbort("owned foreground fixture exited while awaiting state")
                }
                let url = directory.appending(path: "state.json")
                if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                    do {
                        observed = try JSONDecoder().decode(E2EForegroundState.self, from: Data(contentsOf: url))
                    } catch {
                        throw E2EAbort("owned foreground fixture state could not be read: \(error)")
                    }
                    if let observed, observed.processIdentifier == processIdentifier,
                        observed.sequence == sequence, !requireReady || observed.ready
                    {
                        return observed
                    }
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            throw E2EAbort(
                "owned foreground fixture state timed out for sequence \(sequence): \(String(describing: observed))")
        }

    }
#endif
