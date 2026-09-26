import AppKit
import Domain
import Features
import MacPlatform

extension DisplayInfo {
    /// The AppKit screen for this display, matched by display ID (never by index).
    var screen: NSScreen? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == id
        }
    }

    var localizedName: String {
        screen?.localizedName ?? String(localized: "Display \(id)")
    }
}

/// One borderless overlay window per display for region selection (FR-02). A selection starts
/// on one display and is clamped to it, with a visible explanation when the pointer leaves it.
final class RegionOverlayController {
    var onCommit: ((Rect<DesktopSpace>, DisplayInfo) -> Void)?
    var onCancel: (() -> Void)?

    private var windows: [CGDirectDisplayID: OverlayWindow] = [:]

    var isPresented: Bool { !windows.isEmpty }

    func present(displays: [DisplayInfo], notice: String?) {
        let wanted = Set(displays.map(\.id))
        for (id, window) in windows where !wanted.contains(id) {
            window.orderOut(nil)
            windows[id] = nil
        }
        for display in displays {
            if let existing = windows[display.id] {
                existing.selectionView.notice = notice
                continue
            }
            guard let screen = display.screen else { continue }
            let window = OverlayWindow(display: display, screen: screen)
            window.selectionView.notice = notice
            window.selectionView.onCommit = { [weak self] rect, display in self?.onCommit?(rect, display) }
            window.selectionView.onCancel = { [weak self] in self?.onCancel?() }
            windows[display.id] = window
            window.orderFrontRegardless()
        }
        focusWindowUnderPointer()
    }

    func dismiss() {
        for window in windows.values { window.orderOut(nil) }
        windows.removeAll()
    }

    private func focusWindowUnderPointer() {
        let pointer = NSEvent.mouseLocation
        let target = windows.values.first { $0.frame.contains(pointer) } ?? windows.values.first
        guard let target else { return }
        NSApp.activate()
        target.makeKey()
        target.makeFirstResponder(target.selectionView)
    }
}

final class OverlayWindow: NSWindow {
    let selectionView: RegionSelectionView

    init(display: DisplayInfo, screen: NSScreen) {
        selectionView = RegionSelectionView(display: display)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = selectionView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

/// Draws the dimmed screen, the selection, and a live size label in the display's real pixels.
final class RegionSelectionView: NSView {
    var onCommit: ((Rect<DesktopSpace>, DisplayInfo) -> Void)?
    var onCancel: (() -> Void)?
    var notice: String? {
        didSet { needsDisplay = true }
    }

    private let display: DisplayInfo
    private var anchor: CGPoint?
    private var current: CGPoint?
    private var pointerLeftDisplay = false

    init(display: DisplayInfo) {
        self.display = display
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel(String(localized: "Screen area selection"))
        setAccessibilityHelp(Self.instructions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        anchor = point
        current = point
        pointerLeftDisplay = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard anchor != nil else { return }
        let raw = convert(event.locationInWindow, from: nil)
        pointerLeftDisplay = !bounds.contains(raw)
        current = clampedPoint(raw)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            anchor = nil
            current = nil
            pointerLeftDisplay = false
            needsDisplay = true
        }
        guard let rect = selectionRect, rect.width >= 1, rect.height >= 1 else { return }
        onCommit?(desktopRect(for: rect), display)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Escape
            onCancel?()
        case 36, 76:  // Return, keypad Enter: capture the whole display
            onCommit?(display.frame, display)
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        NSColor.black.withAlphaComponent(reduceTransparency ? 0.5 : 0.3).setFill()
        bounds.fill()

        if let rect = selectionRect {
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            let lineWidth: CGFloat = highContrast ? 2 : 1
            NSColor.black.setStroke()
            let outer = NSBezierPath(rect: rect.insetBy(dx: -lineWidth, dy: -lineWidth))
            outer.lineWidth = lineWidth
            outer.stroke()
            NSColor.white.setStroke()
            let inner = NSBezierPath(rect: rect)
            inner.lineWidth = lineWidth
            inner.stroke()
            drawSizeLabel(for: rect)
        }

        var lines = [Self.instructions]
        if let notice { lines.insert(notice, at: 0) }
        if pointerLeftDisplay {
            lines.append(String(localized: "A selection stays on the display where it started."))
        }
        drawBanner(lines.joined(separator: "\n"))
    }

    private func drawSizeLabel(for rect: CGRect) {
        let size = RegionSelection.pixelSize(of: desktopRect(for: rect), on: display)
        let text = String(localized: "\(size.width) × \(size.height) px")
        let origin = CGPoint(x: rect.maxX - 4, y: min(rect.maxY + 6, bounds.maxY - 28))
        drawLabel(text, anchoredAt: origin, alignRight: true)
    }

    private func drawBanner(_ text: String) {
        drawLabel(text, anchoredAt: CGPoint(x: bounds.midX, y: bounds.minY + 48), centered: true)
    }

    private func drawLabel(_ text: String, anchoredAt point: CGPoint, alignRight: Bool = false, centered: Bool = false)
    {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.boundingRect(
            with: CGSize(width: min(bounds.width - 40, 640), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).size
        var origin = point
        if centered { origin.x -= textSize.width / 2 }
        if alignRight { origin.x -= textSize.width }
        // Keep the label (and its background) fully inside the display.
        let margin: CGFloat = 12
        origin.x = min(max(origin.x, bounds.minX + margin), bounds.maxX - textSize.width - margin)
        origin.y = min(max(origin.y, bounds.minY + margin), bounds.maxY - textSize.height - margin)
        let background = CGRect(origin: origin, size: textSize).insetBy(dx: -8, dy: -5)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6).fill()
        string.draw(with: CGRect(origin: origin, size: textSize), options: [.usesLineFragmentOrigin])
    }

    // MARK: Geometry

    private var selectionRect: CGRect? {
        guard let anchor, let current else { return nil }
        return CGRect(
            x: min(anchor.x, current.x), y: min(anchor.y, current.y), width: abs(anchor.x - current.x),
            height: abs(anchor.y - current.y))
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    /// View points (flipped, top-left) → desktop points. The window covers exactly this display.
    private func desktopRect(for rect: CGRect) -> Rect<DesktopSpace> {
        let sx = bounds.width > 0 ? display.frame.width / bounds.width : 1
        let sy = bounds.height > 0 ? display.frame.height / bounds.height : 1
        return Rect(
            x: display.frame.minX + rect.minX * sx, y: display.frame.minY + rect.minY * sy, width: rect.width * sx,
            height: rect.height * sy)
    }

    private static var instructions: String {
        String(
            localized:
                "Drag to select an area. Press Return to capture the whole display or Escape to cancel.")
    }
}
