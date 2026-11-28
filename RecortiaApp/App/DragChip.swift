import AppKit
import Domain
import Features
import MacPlatform

/// Live drag-out sink (FR-07). AppKit can only start a drag inside a mouse event, but the export
/// coordinator produces the sanitized snapshot asynchronously first. So the snapshot is offered on
/// a small floating chip at the pointer; dragging the chip hands receivers a file promise that
/// keeps the sanitized bytes alive until the transfer completes.
final class LiveDragSink: DragSinkService {
    private var panel: (offer: UUID, window: DragChipPanel)?
    private let offers = PendingOffer<DragChipResult>()

    func deliver(_ snapshot: ShareSnapshot, lease: ExportLease) async throws(SinkError) -> DragDeliveryOutcome {
        dismiss()
        guard !lease.isRevoked else { return .canceledByUser }
        guard let image = NSImage(data: snapshot.bytes) else { throw .writeFailed(code: Int(EINVAL)) }
        let result = await offers.wait { offer in
            // Completions carry their offer: a late write from an earlier chip cannot end this one.
            let window = DragChipPanel(snapshot: snapshot, lease: lease, image: image) { [weak self] outcome in
                self?.finish(offer, outcome)
            }
            panel = (offer, window)
            window.presentNearPointer()
        }
        switch result {
        case .delivered: return .delivered
        case .canceled: return .canceledByUser
        case .failed: throw .writeFailed(code: Int(EIO))
        }
    }

    func dismiss() {
        guard let offer = offers.currentID else { return }
        finish(offer, .canceled)
    }

    private func finish(_ offer: UUID, _ outcome: DragChipResult) {
        guard offers.resolve(offer, with: outcome) else { return }
        if let panel, panel.offer == offer {
            panel.window.orderOut(nil)
            self.panel = nil
        }
    }
}

/// How a chip's offer ended. Delivery means the receiver's promised file was written, not merely
/// dropped: AppKit ends the drag session before it asks for the file.
enum DragChipResult: Sendable {
    case delivered, canceled, failed
}

final class DragChipPanel: NSPanel {
    private let onEnd: @MainActor @Sendable (DragChipResult) -> Void

    init(
        snapshot: ShareSnapshot, lease: ExportLease, image: NSImage,
        onEnd: @escaping @MainActor @Sendable (DragChipResult) -> Void
    ) {
        self.onEnd = onEnd
        super.init(
            contentRect: NSRect(
                x: 0, y: 0, width: DragChipView.size.width + 2 * DesignTokens.Space.m,
                height: DragChipView.size.height + 2 * DesignTokens.Space.m),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false)
        title = String(localized: "Drag to Export")
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = SpacePolicy.joinsAllSpaces
        let chip = DragChipView(snapshot: snapshot, lease: lease, image: image) { [weak self] outcome in
            self?.onEnd(outcome)
        }
        // The title says what to do; the chip needs no caption.
        let stack = NSStackView(views: [chip])
        stack.orientation = .vertical
        let inset = DesignTokens.Space.m
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        contentView = stack
    }

    func presentNearPointer() {
        let pointer = NSEvent.mouseLocation
        var origin = NSPoint(x: pointer.x + 16, y: pointer.y - frame.height - 16)
        if let visible = ScreenChoice.screen()?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - frame.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - frame.height)
        }
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        onEnd(.canceled)
    }

    override func performClose(_ sender: Any?) {
        onEnd(.canceled)
    }

    override func close() {
        super.close()
        onEnd(.canceled)
    }
}

/// The draggable thumbnail. Accessible as a button whose action explains how to drag.
final class DragChipView: NSImageView, NSDraggingSource {
    static let size = NSSize(width: 196, height: 140)
    private let provider: DragOutProvider
    private let onEnd: @MainActor @Sendable (DragChipResult) -> Void

    init(
        snapshot: ShareSnapshot, lease: ExportLease, image: NSImage,
        onEnd: @escaping @MainActor @Sendable (DragChipResult) -> Void
    ) {
        // The offer stays pending (and revocable) until the receiver's write finishes.
        provider = DragOutProvider(snapshot: snapshot, lease: lease) { outcome in
            Task { @MainActor in
                switch outcome {
                case .written: onEnd(.delivered)
                case .revoked: onEnd(.canceled)
                case .failed: onEnd(.failed)
                }
            }
        }
        self.onEnd = onEnd
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        self.image = image
        imageScaling = .scaleProportionallyDown
        // The snapshot leaves only through the drag; the view's own Copy would bypass its lease.
        allowsCutCopyPaste = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Exported image, draggable"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        // The document changed since this offer was made: never start a drag of stale pixels.
        guard !provider.lease.isRevoked else {
            onEnd(.canceled)
            return
        }
        let item = NSDraggingItem(pasteboardWriter: provider.makeFilePromiseProvider())
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    {
        context == .outsideApplication ? .copy : []
    }

    // Delivery is reported by the promise write, not here: the session ends before the receiver
    // asks for the file. An abandoned drag, or a receiver that never asks, keeps the chip so the
    // user can try again or close it.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {}
}
