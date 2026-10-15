import AppKit
import Foundation

@main
@MainActor
enum ForegroundHostMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        do {
            let host = try ForegroundHost(arguments: ProcessInfo.processInfo.arguments)
            application.delegate = host
            application.run()
            withExtendedLifetime(host) {}
        } catch {
            log("owned foreground fixture setup failed: \(error)")
            exit(2)
        }
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[foreground-host] \(message)\n".utf8))
    }
}

@MainActor
private final class ForegroundHost: NSObject, NSApplicationDelegate {
    private enum SetupError: Error { case invalidArguments, invalidDirectory }

    private let directory: URL
    private let session: String
    private let parent: NSRunningApplication
    private let window: NSWindow
    private var sequence = 0
    private var observer: (any NSObjectProtocol)?
    private var lifetime: Task<Void, Never>?

    init(arguments: [String]) throws {
        guard let index = arguments.firstIndex(of: E2EForegroundState.argument),
            index + 3 < arguments.count, arguments[index + 1].hasPrefix("/"),
            let parentPID = pid_t(arguments[index + 2]), parentPID > 0,
            parentPID != ProcessInfo.processInfo.processIdentifier,
            let parent = NSRunningApplication(processIdentifier: parentPID), !parent.isTerminated,
            parent.bundleIdentifier == "dev.mvneves.Recortia.E2E",
            let uuid = UUID(uuidString: arguments[index + 3])
        else { throw SetupError.invalidArguments }
        let directory = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard directory.lastPathComponent == "foreground-\(uuid.uuidString)",
            FileManager.default.fileExists(atPath: directory.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw SetupError.invalidDirectory }
        self.directory = directory
        session = uuid.uuidString
        self.parent = parent
        let visible = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        window = NSWindow(
            contentRect: NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 360, height: 220),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Recortia E2E owned foreground fixture"
        window.collectionBehavior = SpacePolicy.followsActiveSpace
        window.level = .normal
        window.backgroundColor = NSColor(calibratedWhite: 0.3, alpha: 1)
        window.isOpaque = true
        window.alphaValue = 1
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPresence.shared.start()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: E2EForegroundState.requestName(session), object: session, queue: .main
        ) { [weak self] notification in
            guard let object = notification.object as? String,
                let info = notification.userInfo, let command = info["command"] as? String,
                let sequence = info["sequence"] as? Int, let parentPID = info["parentPID"] as? Int32
            else { return }
            let frame: CGRect?
            if let x = info["x"] as? Double, let y = info["y"] as? Double,
                let width = info["width"] as? Double, let height = info["height"] as? Double
            {
                frame = CGRect(x: x, y: y, width: width, height: height)
            } else {
                frame = nil
            }
            Task { @MainActor [weak self] in
                self?.handle(command, sequence: sequence, session: object, parentPID: parentPID, frame: frame)
            }
        }
        present()
        lifetime = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + .seconds(120)
            while ContinuousClock.now < deadline {
                guard let self else { return }
                if self.parent.isTerminated { NSApp.terminate(nil); return }
                self.writeState()
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            }
            NSApp.terminate(nil)
        }
    }

    private func present() {
        AppPresence.shared.windowWillAppear()
        window.makeKeyAndOrderFront(nil)
        AppPresence.shared.activate()
    }

    private func handle(_ command: String, sequence: Int, session: String, parentPID: pid_t, frame: CGRect?) {
        guard session == self.session, parentPID == parent.processIdentifier, !parent.isTerminated,
            sequence == self.sequence + 1
        else { return }
        switch command {
        case "cover":
            guard let frame, E2EForegroundState.valid(frame) else { return }
            window.setFrame(frame, display: true)
            present()
        case "activate":
            present()
        case "yield":
            NSApp.yieldActivation(to: parent)
        default:
            return
        }
        self.sequence = sequence
        writeState()
    }

    private func writeState() {
        let state = E2EForegroundState(
            processIdentifier: ProcessInfo.processInfo.processIdentifier, windowID: window.windowNumber,
            frame: window.frame, key: window.isKeyWindow, active: NSApp.isActive,
            foreground: NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier,
            visible: window.isVisible, unoccluded: window.occlusionState.contains(.visible),
            onActiveSpace: window.isOnActiveSpace, opaque: window.isOpaque && window.alphaValue == 1,
            sequence: sequence)
        do {
            try JSONEncoder().encode(state).write(to: directory.appending(path: "state.json"), options: .atomic)
        } catch {
            ForegroundHostMain.log("owned foreground fixture state write failed: \(error)")
            NSApp.terminate(nil)
        }
    }
}
