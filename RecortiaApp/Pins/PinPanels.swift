import AppKit
import Domain
import Features
import SwiftUI

/// Reference pins (FR-09, ADR-007): ordinary normal-level panels (never click-through) on every
/// Space, movable by dragging, with opacity, zoom, copy, drag-out, and an explicit close.
/// Escape or ⌘W closes the focused pin.
final class PinsUIController {
    private let model: PinsModel
    private var panels: [PinID: PinPanel] = [:]
    private var lastBringForward = 0
    private var loop: ObservationLoop?

    init(model: PinsModel) {
        self.model = model
        lastBringForward = model.bringForwardRequest
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    private func render() {
        let pins = model.pins
        let ids = Set(pins.map(\.id))
        for (id, panel) in panels where !ids.contains(id) {
            panel.close()
            panels[id] = nil
        }
        for pin in pins where panels[pin.id] == nil {
            let panel = PinPanel(pinID: pin.id, model: model)
            panels[pin.id] = panel
            panel.presentNearPointer()
        }
        if model.bringForwardRequest != lastBringForward {
            lastBringForward = model.bringForwardRequest
            for panel in panels.values { panel.orderFrontRegardless() }
        }
    }
}

final class PinPanel: NSPanel {
    /// Chosen once, so the pin is sized for the screen it appears on (FR-09).
    private let targetScreen = ScreenChoice.screen()

    init(pinID: PinID, model: PinsModel) {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        // An ordinary window, not a floating one, so window switchers list it (ADR-007).
        isFloatingPanel = false
        level = .normal
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        hasShadow = true
        // Transparent window: the pin's opacity must reveal what is behind it (FR-09); only the
        // control bar paints a background.
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = SpacePolicy.joinsAllSpaces
        title = String(localized: "Pin")
        setAccessibilityLabel(String(localized: "Pinned screenshot"))
        let fit = Self.fitScale(for: model.pin(for: pinID), visibleFrame: targetScreen?.visibleFrame)
        let controller = NSHostingController(
            rootView: PinContentView(pinID: pinID, model: model, fitScale: fit))
        controller.sizingOptions = [.preferredContentSize]
        contentViewController = controller
    }

    override var canBecomeKey: Bool { true }

    func presentNearPointer() {
        let pointer = NSEvent.mouseLocation
        if let visible = targetScreen?.visibleFrame {
            let size = frame.size
            let x = min(max(pointer.x - size.width / 2, visible.minX), visible.maxX - size.width)
            let y = min(max(pointer.y - size.height / 2, visible.minY), visible.maxY - size.height)
            setFrameOrigin(CGPoint(x: x, y: y))
        }
        AppPresence.shared.activate()
        makeKeyAndOrderFront(nil)
    }

    /// Shrinks very large images so a new pin fits the visible frame of the screen it appears on;
    /// the pin's own zoom applies on top.
    static func fitScale(for pin: Pin?, visibleFrame visible: CGRect?) -> Double {
        guard let pin, let visible else { return 1 }
        let width = Double(pin.image.width) / pin.displayScale
        let height = Double(pin.image.height) / pin.displayScale
        guard width > 0, height > 0 else { return 1 }
        return min(1, visible.width * 0.6 / width, visible.height * 0.6 / height)
    }
}

/// The pin's content: the sanitized image and an always-visible control bar.
struct PinContentView: View {
    let pinID: PinID
    let model: PinsModel
    let fitScale: Double
    /// The latest copy or drag-out outcome, in the editor's words (PIN-02).
    @State private var status: String?

    var body: some View {
        if let pin = model.pin(for: pinID) {
            PinView(
                pin: pin, fitScale: fitScale, status: status,
                onOpacity: { model.setOpacity($0, for: pinID) },
                onZoom: { model.setZoom($0, for: pinID) },
                onExport: { action in Task { await export(action) } },
                onClose: { model.close(pinID) })
        }
    }

    private func export(_ action: PinExportAction) async {
        status = nil
        let outcome = await model.export(action, pinID)
        guard outcome != .canceled, model.pin(for: pinID) != nil else { return }
        let message = EditorStrings.exportMessage(outcome)
        status = message
        AccessibilityNotification.Announcement(message).post()
        // Failures stay until the next action; a success note clears itself.
        guard outcome.didWrite else { return }
        try? await Task.sleep(for: .seconds(4))
        if status == message { status = nil }
    }
}

struct PinView: View {
    let pin: Pin
    let fitScale: Double
    var status: String?
    let onOpacity: @MainActor (Double) -> Void
    let onZoom: (Double) -> Void
    let onExport: (PinExportAction) -> Void
    let onClose: () -> Void

    private var imageSize: CGSize {
        let scale = fitScale * pin.zoom / pin.displayScale
        return CGSize(width: Double(pin.image.width) * scale, height: Double(pin.image.height) * scale)
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(decorative: pin.image, scale: 1)
                .resizable()
                .interpolation(pin.zoom * fitScale >= 2 ? .none : .high)
                .frame(width: imageSize.width, height: imageSize.height)
                .opacity(pin.opacity)
                .accessibilityLabel(Text("Pinned screenshot"))
            controls
            if let status {
                // Wraps within the pin instead of widening it.
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: max(imageSize.width, 240), alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Label("Close Pin", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .help(Text("Close Pin"))
            .keyboardShortcut(.cancelAction)
            // ⌘W closes the focused pin as well.
            Button("Close Pin", action: onClose)
                .keyboardShortcut("w")
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            if pin.exportID != nil {
                Divider().frame(height: 16)
                Button {
                    onExport(.copy)
                } label: {
                    Label(String(localized: "Copy", table: "Editor"), systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .help(Text(String(localized: "Copy", table: "Editor")))
                .keyboardShortcut("c")
                Button {
                    onExport(.drag)
                } label: {
                    Label(String(localized: "Drag Out", table: "Editor"), systemImage: "hand.draw")
                }
                .labelStyle(.iconOnly)
                .help(Text(String(localized: "Drag Out", table: "Editor")))
            }
            Divider().frame(height: 16)
            Button {
                onZoom(pin.zoom / 1.25)
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .help(Text("Zoom Out"))
            .keyboardShortcut("-")
            Text(pin.zoom, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .accessibilityLabel(Text("Zoom \(Int((pin.zoom * 100).rounded())) percent"))
            Button {
                onZoom(pin.zoom * 1.25)
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .help(Text("Zoom In"))
            .keyboardShortcut("=")
            Divider().frame(height: 16)
            Slider(
                value: Binding(get: { pin.opacity }, set: onOpacity), in: PinsModel.opacityRange
            ) {
                Text("Opacity")
            }
            .labelsHidden()
            .frame(minWidth: 60, maxWidth: 120)
            .accessibilityLabel(Text("Opacity"))
            .accessibilityValue(Text(pin.opacity, format: .percent.precision(.fractionLength(0))))
            .help(Text("Opacity"))
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minWidth: 240)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#if DEBUG
    #Preview("Pin") {
        if let image = PreviewSupport.image() {
            let model = EditorPreviewFactory.environment().pins
            let id = try? model.add(image, source: nil, displayScale: 2)
            if let id {
                PinContentView(pinID: id, model: model, fitScale: 1)
            }
        }
    }
#endif
