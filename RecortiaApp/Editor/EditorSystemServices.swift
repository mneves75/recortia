import AppKit
import Features
import MacPlatform

// Live adapters for the editor's system boundaries. The composition root passes them into
// `EditorEnvironment` (text clipboard, link opener). Drag-out needs no adapter here: it runs
// through `ExportCoordinator`'s drag action and the app's `DragSinkService`.

/// Plain-text clipboard writes, only from explicit Copy actions. No other representation is
/// written, and nothing is read.
final class PasteboardTextClipboard: TextClipboardService {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func writePlainText(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

/// Opens web links in the default browser, re-checking the policy at the boundary.
final class WorkspaceLinkOpener: ExternalLinkOpenerService {
    func open(_ url: URL) -> Bool {
        guard ExternalLinkPolicy.canOpen(url) else { return false }
        return NSWorkspace.shared.open(url)
    }
}
