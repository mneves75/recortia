import AppKit
import Domain
import Features
import MacPlatform

/// Live drag-out sink (FR-07). AppKit can only start a drag inside a mouse event, but the export
/// coordinator produces the sanitized snapshot asynchronously first. So the snapshot is offered on
/// a small floating chip at the pointer; dragging the chip hands receivers a file promise that
/// keeps the sanitized bytes alive until the transfer completes.
final class LiveDragSink: DragSinkService {
    private var panel: DragChipPanel?
    private var continuation: CheckedContinuation<DragDeliveryOutcome, Never>?

    func deliver(_ snapshot: ShareSnapshot) async throws(SinkError) -> DragDeliveryOutcome {
        finish(.canceledByUser)
        guard let image = NSImage(data: snapshot.bytes) else { throw .writeFailed(code: Int(EINVAL)) }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let panel = DragChipPanel(snapshot: snapshot, image: image) { [weak self] outcome in
                self?.finish(outcome)
            }
            self.panel = panel
            panel.presentNearPointer()
        }
    }

    private func finish(_ outcome: DragDeliveryOutcome) {
        panel?.orderOut(nil)
        panel = nil
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

final class DragChipPanel: NSPanel {
    private let onEnd: (DragDeliveryOutcome) -> Void

    init(snapshot: ShareSnapshot, image: NSImage, onEnd: @escaping (DragDeliveryOutcome) -> Void) {
        self.onEnd = onEnd
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 190), styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false)
        title = String(localized: "Drag to Export")
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let chip = DragChipView(snapshot: snapshot, image: image) { [weak self] in self?.onEnd(.delivered) }
        let label = NSTextField(labelWithString: String(localized: "Drag the image into another app."))
        label.alignment = .center
        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [chip, label])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        contentView = stack
    }

    func presentNearPointer() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        var origin = NSPoint(x: pointer.x + 16, y: pointer.y - frame.height - 16)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - frame.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - frame.height)
        }
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        onEnd(.canceledByUser)
    }

    override func performClose(_ sender: Any?) {
        onEnd(.canceledByUser)
    }

    override func close() {
        super.close()
        onEnd(.canceledByUser)
    }
}

/// The draggable thumbnail. Accessible as a button whose action explains how to drag.
final class DragChipView: NSImageView, NSDraggingSource {
    private let provider: DragOutProvider
    private let onDelivered: () -> Void

    init(snapshot: ShareSnapshot, image: NSImage, onDelivered: @escaping () -> Void) {
        provider = DragOutProvider(snapshot: snapshot)
        self.onDelivered = onDelivered
        super.init(frame: NSRect(x: 0, y: 0, width: 196, height: 140))
        self.image = image
        imageScaling = .scaleProportionallyDown
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 196).isActive = true
        heightAnchor.constraint(equalToConstant: 140).isActive = true
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Exported image, draggable"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: provider.makeFilePromiseProvider())
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // An abandoned drag keeps the chip so the user can try again or close it.
        if !operation.isEmpty { onDelivered() }
    }
}
