// Fullscreen host: a regular app whose single empty window enters its own fullscreen Space.
// Stands in for "another app's fullscreen Space". Quits on SIGTERM.
import AppKit

final class Host: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "SpaceProbeHost"
        window.collectionBehavior = [.fullScreenPrimary]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.window.toggleFullScreen(nil) }
        // A user action would let the probe activate; cooperative activation needs the active
        // app to yield explicitly when no event is involved.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("SpaceProbeYield"), object: nil, queue: .main
        ) { note in
            guard let raw = note.object as? String, let pid = pid_t(raw),
                let target = NSRunningApplication(processIdentifier: pid)
            else { return }
            NSApp.yieldActivation(to: target)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Host()
app.delegate = delegate
signal(SIGTERM) { _ in exit(0) }
app.run()
