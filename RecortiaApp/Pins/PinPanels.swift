import AppKit
import Domain
import Features
import SwiftUI

/// Floating reference pins (FR-09): interactive panels (never click-through), movable by
/// dragging, with opacity, zoom, and an explicit close. Escape or ⌘W closes the focused pin.
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
        isFloatingPanel = true
        level = .floating
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
        NSApp.activate()
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

    var body: some View {
        if let pin = model.pin(for: pinID) {
            PinView(
                pin: pin, fitScale: fitScale,
                onOpacity: { model.setOpacity($0, for: pinID) },
                onZoom: { model.setZoom($0, for: pinID) },
                onClose: { model.close(pinID) })
        }
    }
}

struct PinView: View {
    let pin: Pin
    let fitScale: Double
    let onOpacity: @MainActor (Double) -> Void
    let onZoom: (Double) -> Void
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
            let model = PinsModel(renderer: PreviewRenderer(), settings: PreviewSupport.settings())
            let id = try? model.add(image, source: nil, displayScale: 2)
            if let id {
                PinContentView(pinID: id, model: model, fitScale: 1)
            }
        }
    }

    private final class PreviewRenderer: RenderService {
        struct Unavailable: Error {}
        func render(_ document: Domain.Document, scale: Double) async throws -> CGImage { throw Unavailable() }
        func renderBase(_ document: Domain.Document, scale: Double) async throws -> CGImage { throw Unavailable() }
    }
#endif
