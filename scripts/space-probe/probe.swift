// Accessory (LSUIElement-like) probe. Shows ONE window configured like a Recortia surface and
// reports Space facts as JSON. Reads only window-list metadata for its own PID and the host PID
// (no titles, no pixels; no Screen Recording needed).
//
// Usage: probe <variant> <mode>
//   mode "fresh": wait for the fullscreen host (pid in HOST_PID_FILE), then create + present.
//   mode "stale": create + present now on the current desktop Space, write READY_FILE, wait for
//                 the host to become frontmost, then present the SAME window again.
// FORCE=1 uses activate(ignoringOtherApps:) to stand in for user-granted activation.
import AppKit

let variant = CommandLine.arguments[1]
let mode = CommandLine.arguments[2]
let force = ProcessInfo.processInfo.environment["FORCE"] == "1"
let readyFile = ProcessInfo.processInfo.environment["READY_FILE"] ?? ""
let hostPIDFile = ProcessInfo.processInfo.environment["HOST_PID_FILE"] ?? ""

func activateApp() { if force { NSApp.activate(ignoringOtherApps: true) } else { NSApp.activate() } }

func windows(of pid: pid_t) -> [[String: Any]] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
}

/// The window list is ordered front to back: is our window listed before the host's largest one?
func zAboveIn(_ hostPID: pid_t) -> String {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    func area(_ w: [String: Any]) -> Double {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (b["Width"] ?? 0) * (b["Height"] ?? 0)
    }
    let mine = list.firstIndex { ($0[kCGWindowOwnerPID as String] as? pid_t) == getpid() }
    let hostWindows = list.enumerated().filter { ($0.element[kCGWindowOwnerPID as String] as? pid_t) == hostPID }
    guard let host = hostWindows.max(by: { area($0.element) < area($1.element) })?.offset else { return "no-host" }
    guard let mine else { return "not-listed" }
    return mine < host ? "above" : "below"
}

func readHostPID() -> pid_t? {
    guard let text = try? String(contentsOfFile: hostPIDFile, encoding: .utf8) else { return nil }
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

final class Probe: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var spaceChanges = 0
    var hostPID: pid_t = 0
    var hostFrontBefore = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.spaceChanges += 1 }
        if mode == "stale" {
            window = make()
            present()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                FileManager.default.createFile(atPath: readyFile, contents: Data())
                self.waitForHost()
            }
        } else {
            waitForHost()
        }
    }

    func waitForHost() {
        if let pid = readHostPID(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
            windows(of: pid).count >= 1
        {
            hostPID = pid
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.go() }  // let fullscreen settle
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.waitForHost() }
        }
    }

    func go() {
        hostFrontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier == hostPID
        spaceChanges = 0
        let onActiveBefore = window?.isOnActiveSpace
        if window == nil { window = make() }
        present()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.report(onActiveBefore: onActiveBefore)
            exit(0)
        }
    }

    func make() -> NSWindow {
        let rect = NSRect(x: 300, y: 300, width: 320, height: 200)
        func panel(_ style: NSWindow.StyleMask) -> NSPanel {
            let p = NSPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            return p
        }
        let w: NSWindow
        switch variant {
        case "default", "activate-only-default":
            w = NSWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        case "follow-activate-first", "follow-order-first", "activate-only-follow":
            w = NSWindow(
                contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        case "panel-activating":
            w = panel([.titled, .fullSizeContentView])
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        case "panel-nonactivating":
            w = panel([.titled, .fullSizeContentView, .nonactivatingPanel])
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        case "panel-nonactivating-alljoin":
            w = panel([.titled, .fullSizeContentView, .nonactivatingPanel])
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        case "overlay":
            w = panel([.borderless, .nonactivatingPanel])
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.backgroundColor = NSColor.black.withAlphaComponent(0.05)
        default:
            print("{\"error\":\"unknown variant \(variant)\"}")
            exit(2)
        }
        w.isReleasedWhenClosed = false
        w.title = "probe"
        return w
    }

    var presented = false
    func present() {
        defer { presented = true }
        if variant.hasPrefix("activate-only") {
            if presented { activateApp() } else { activateApp(); window.makeKeyAndOrderFront(nil) }
            return
        }
        switch variant {
        case "default", "follow-activate-first", "panel-activating":
            activateApp()
            window.makeKeyAndOrderFront(nil)
        case "follow-order-first":
            window.orderFrontRegardless()
            window.makeKey()
            activateApp()
        default:  // nonactivating panels and the overlay never activate
            window.orderFrontRegardless()
            window.makeKey()
        }
    }

    func zAbove() -> String { zAboveIn(hostPID) }

    func report(onActiveBefore: Bool?) {
        let facts: [String: Any] = [
            "variant": variant, "mode": mode, "force": force,
            "hostFrontBefore": hostFrontBefore,
            "windowOnActiveSpaceBefore": onActiveBefore.map { $0 ? "yes" : "no" } ?? "new",
            "spaceChanges": spaceChanges,
            "windowVisible": window.isVisible,
            "windowOnActiveSpace": window.isOnActiveSpace,
            "probeOnScreen": windows(of: getpid()).count,
            "hostOnScreenAfter": windows(of: hostPID).count,
            "appActive": NSApp.isActive,
            "probeAboveHost": zAbove(),
            "frontmostIsHost": NSWorkspace.shared.frontmostApplication?.processIdentifier == hostPID,
        ]
        let data = try! JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        fflush(stdout)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Probe()
app.delegate = delegate
app.run()
