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
///
/// With pre-building (A-13 step 2) every display keeps a hidden, policy-applied panel that a
/// capture orders in instead of constructing one; dismissal hides it again for the next capture.
final class RegionOverlayController {
    /// The shipped default (decisions 2026-11-21, A-13 step 2): showing an overlay is mostly
    /// constructing its full-screen panel, so it is pre-built. Unproven until a native run.
    static let prebuildsByDefault = true

    var onCommit: ((Rect<DesktopSpace>, DisplayInfo) -> Void)?
    var onCancel: (() -> Void)?
    /// Space, as in the macOS Screenshot app: continue as a window selection.
    var onSwitchToWindow: (() -> Void)?
    var onAspectChange: ((SelectionAspect) -> Void)?
    var onFreezeToggle: ((DisplayInfo?) -> Void)?

    private var windows: [CGDirectDisplayID: OverlayWindow] = [:]
    private let pool: WindowSparePool<DisplayInfo, OverlayWindow>

    init(
        prebuilds: Bool = RegionOverlayController.prebuildsByDefault,
        makeWindow: @escaping (DisplayInfo, NSScreen) -> OverlayWindow = { OverlayWindow(display: $0, screen: $1) }
    ) {
        pool = WindowSparePool(isEnabled: prebuilds) { display in display.screen.map { makeWindow(display, $0) } }
    }

    var isPresented: Bool { !windows.isEmpty }

    /// The panels on screen now, for measurement.
    var presentedWindows: [OverlayWindow] { Array(windows.values) }

    /// The hidden panel kept for `display`, if any.
    func spare(for display: DisplayInfo) -> OverlayWindow? { pool.spare(for: display) }

    /// Builds and draws a hidden panel for each display, replacing those of displays that changed
    /// or went away. Does nothing without pre-building.
    func prepare(displays: [DisplayInfo]) {
        pool.prepare(displays)
        for display in displays { pool.spare(for: display)?.displayIfNeeded() }
    }

    func present(
        displays: [DisplayInfo], notice: String?, allowsWindowSwitch: Bool, aspect: SelectionAspect?,
        snapFrames: [Rect<DesktopSpace>], allowsFreeze: Bool = false, freeze: CaptureCoordinator.RegionFreeze? = nil
    ) {
        let wanted = Set(displays.map(\.id))
        for (id, window) in windows where !wanted.contains(id) {
            hide(window)
            windows[id] = nil
        }
        for display in displays {
            if let existing = windows[display.id] {
                configure(existing.selectionView, notice, allowsWindowSwitch, aspect, snapFrames, allowsFreeze, freeze)
                continue
            }
            guard let screen = display.screen else { continue }
            let reused = pool.spare(for: display) != nil
            guard let window = pool.take(display) else { continue }
            let view = window.selectionView
            configure(view, notice, allowsWindowSwitch, aspect, snapFrames, allowsFreeze, freeze)
            view.onSwitchToWindow = { [weak self] in self?.onSwitchToWindow?() }
            view.onCommit = { [weak self] rect, display in self?.onCommit?(rect, display) }
            view.onCancel = { [weak self] in self?.onCancel?() }
            view.onAspectChange = { [weak self] in self?.onAspectChange?($0) }
            view.onFreezeToggle = { [weak self] in
                guard let self else { return }
                let pointer = NSEvent.mouseLocation
                let target = self.windows.values.first { $0.frame.contains(pointer) }
                self.onFreezeToggle?(target?.display ?? (self.windows.count == 1 ? display : nil))
            }
            view.onSelectionBegan = { [weak self, weak view] in
                guard let self else { return }
                for other in self.windows.values where other.selectionView !== view {
                    other.selectionView.clearSelection()
                }
            }
            windows[display.id] = window
            if reused {
                if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
                // Drawn while hidden, so ordering in never shows the previous capture's frame.
                window.displayIfNeeded()
            }
            window.orderFrontRegardless()
        }
        focusWindowUnderPointer()
    }

    func dismiss() {
        for window in windows.values { hide(window) }
        windows.removeAll()
    }

    /// Orders `window` out and keeps it for the next capture when pre-building wants it.
    private func hide(_ window: OverlayWindow) {
        window.orderOut(nil)
        window.selectionView.resetSelection()
        // A panel that drew screen pixels is discarded with its backing store.
        if window.selectionView.hasShownFrozenFrame {
            window.close()
        } else {
            pool.giveBack(window, for: window.display)
        }
    }

    private func configure(
        _ view: RegionSelectionView, _ notice: String?, _ allowsWindowSwitch: Bool, _ aspect: SelectionAspect?,
        _ snapFrames: [Rect<DesktopSpace>], _ allowsFreeze: Bool, _ freeze: CaptureCoordinator.RegionFreeze?
    ) {
        view.notice = notice
        view.allowsWindowSwitch = allowsWindowSwitch
        view.offersAspect = aspect != nil
        view.aspect = aspect ?? .free
        view.snapFrames = snapFrames
        view.configureFreeze(allowed: allowsFreeze, freeze)
    }

    private func focusWindowUnderPointer() {
        let pointer = NSEvent.mouseLocation
        let target = windows.values.first { $0.frame.contains(pointer) } ?? windows.values.first
        guard let target else { return }
        target.makeKey()
        target.makeFirstResponder(target.selectionView)
    }
}

final class OverlayWindow: NSPanel {
    let display: DisplayInfo
    let selectionView: RegionSelectionView

    init(display: DisplayInfo, screen: NSScreen) {
        self.display = display
        selectionView = RegionSelectionView(display: display)
        super.init(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // A global shortcut must select the current desktop without activating Recortia's
        // editor in another Space. Nonactivating panels can still own the keyboard responder.
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .screenSaver
        collectionBehavior = SpacePolicy.joinsAllSpaces.union([.stationary, .ignoresCycle])
        contentView = selectionView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Draws the dimmed screen, the selection, snap guides, and a size label in the display's real
/// pixels with the aspect control. Release commits the dragged area at once; after an arrow key
/// the selection stays, and Return commits it (A-4).
final class RegionSelectionView: NSView {
    var onCommit: ((Rect<DesktopSpace>, DisplayInfo) -> Void)?
    var onCancel: (() -> Void)?
    var onSwitchToWindow: (() -> Void)?
    var onAspectChange: ((SelectionAspect) -> Void)?
    var onFreezeToggle: (() -> Void)?
    /// A drag began here, so the other displays' overlays drop their selections.
    var onSelectionBegan: (() -> Void)?
    var notice: String? {
        didSet {
            setAccessibilityHelp(accessibilityInstructions)
            needsDisplay = true
        }
    }
    /// Whether Space switches to a window selection (a plain region capture, not Capture Text).
    var allowsWindowSwitch = false {
        didSet {
            setAccessibilityHelp(accessibilityInstructions)
            needsDisplay = true
        }
    }
    /// Whether the size label offers the aspect control; without it a selection is free.
    var offersAspect = true {
        didSet {
            aspectControl.isHidden = !offersAspect
            selectionDidChange()
        }
    }
    var aspect = SelectionAspect.free {
        didSet {
            guard aspect != oldValue else { return }
            aspectControl.selectedSegment = SelectionAspect.allCases.firstIndex(of: aspect) ?? 0
            if let held {
                self.held = RegionPrecision.fitted(
                    held, to: aspect, within: localBounds, minimumSide: RegionSelection.minimumSide)
            } else if isDragging {
                resolveDrag()
            }
            selectionDidChange()
        }
    }
    /// Other apps' window frames in desktop points; with the display's edges, what a drag snaps to.
    var snapFrames: [Rect<DesktopSpace>] = [] {
        didSet { if isDragging, held == nil { resolveDrag() } }
    }

    private let display: DisplayInfo
    private let aspectControl: AspectControl
    private var anchor: Point<DisplaySpace>?
    private var pointer: Point<DisplaySpace>?
    private var drag: SelectionDrag<DisplaySpace>?
    /// A selection the keyboard adjusted: the pointer no longer drives it, and Return commits it.
    private var held: Rect<DisplaySpace>?
    private var isDragging = false
    private var keys = SelectionKeys()
    private var pointerLeftDisplay = false
    private var allowsFreeze = false
    private var isFreezing = false
    private var frozenImage: CGImage?
    private var magnifierPointer: CGPoint?
    private var magnifierTracking: NSTrackingArea?
    private(set) var hasShownFrozenFrame = false

    init(display: DisplayInfo) {
        self.display = display
        aspectControl = AspectControl(
            labels: SelectionAspect.allCases.map(Self.title), trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel(String(localized: "Screen area selection"))
        setAccessibilityHelp(instructions)
        aspectControl.target = self
        aspectControl.action = #selector(aspectChosen(_:))
        aspectControl.controlSize = .small
        aspectControl.selectedSegment = 0
        // The overlay keeps the keyboard; the control is for the pointer and VoiceOver.
        aspectControl.refusesFirstResponder = true
        // The overlay is two-tone: the control renders the same in light and dark appearance.
        aspectControl.appearance = NSAppearance(named: .darkAqua)
        aspectControl.setAccessibilityLabel(String(localized: "Aspect ratio"))
        addSubview(aspectControl)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Whether a drag is in progress or a nudged selection is held.
    var hasSelection: Bool { selection != nil }
    var showsFrozenFrame: Bool { frozenImage != nil }

    /// Forgets the selection, the held modifiers and the window frames, so a reused overlay starts
    /// without the previous capture's selection, ratio drag, snap guide or snap targets.
    func resetSelection() {
        clearSelection()
        keys = SelectionKeys()
        snapFrames = []
        configureFreeze(allowed: false, nil)
    }

    func configureFreeze(allowed: Bool, _ freeze: CaptureCoordinator.RegionFreeze?) {
        let image: CGImage?
        let preparing: Bool
        switch freeze {
        case .frozen(let frame):
            image = frame.image
            preparing = false
        case .preparing:
            image = nil
            preparing = true
        case nil:
            image = nil
            preparing = false
        }
        guard allowsFreeze != allowed || isFreezing != preparing || frozenImage !== image else { return }
        if !preparing, image == nil, isFreezing || showsFrozenFrame {
            clearSelection()
        }
        if frozenImage !== image {
            frozenImage = image
            window?.acceptsMouseMovedEvents = image != nil
            if image != nil {
                hasShownFrozenFrame = true
                magnifierPointer = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
            } else {
                magnifierPointer = nil
            }
            updateTrackingAreas()
        }
        allowsFreeze = allowed
        isFreezing = preparing
        setAccessibilityHelp(accessibilityInstructions)
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let magnifierTracking { removeTrackingArea(magnifierTracking) }
        magnifierTracking = nil
        guard frozenImage != nil else { return }
        let tracking = NSTrackingArea(
            rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self, userInfo: nil)
        addTrackingArea(tracking)
        magnifierTracking = tracking
    }

    override func layout() {
        super.layout()
        aspectControl.frame = chip().control
    }

    /// The selection in view points, while dragging or held.
    var selection: Rect<DisplaySpace>? {
        if let held { return held }
        guard let anchor, let corner = drag?.corner else { return nil }
        return Rect(spanning: anchor, corner)
    }

    /// The guides the dragged edges lie on.
    var visibleGuides: [SnapGuide<DisplaySpace>] {
        held == nil && isDragging ? drag?.guides ?? [] : []
    }

    /// Drops this display's selection, as when a drag begins on another display.
    func clearSelection() {
        anchor = nil
        pointer = nil
        drag = nil
        held = nil
        isDragging = false
        pointerLeftDisplay = false
        selectionDidChange()
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        onSelectionBegan?()
        clearSelection()
        keys = Self.keys(event.modifierFlags)
        let start = RegionPrecision.snappedAnchor(
            localPoint(convert(event.locationInWindow, from: nil)), keys: keys, guides: snapGuides())
        anchor = start.corner
        pointer = start.corner
        drag = start
        isDragging = true
        selectionDidChange()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, held == nil, anchor != nil else { return }
        let raw = convert(event.locationInWindow, from: nil)
        if frozenImage != nil { magnifierPointer = raw }
        pointerLeftDisplay = !bounds.contains(raw)
        pointer = localPoint(raw)
        keys = Self.keys(event.modifierFlags)
        resolveDrag()
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        magnifierPointer = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        magnifierPointer = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        pointerLeftDisplay = false
        guard held == nil else { return selectionDidChange() }
        let rect = committable
        if isFreezing, let rect {
            held = rect
            selectionDidChange()
            return
        }
        clearSelection()
        guard let rect else { return }
        onCommit?(desktopRect(for: rect), display)
    }

    override func flagsChanged(with event: NSEvent) {
        keys = Self.keys(event.modifierFlags)
        if isDragging, held == nil { resolveDrag() }
    }

    override func keyDown(with event: NSEvent) {
        if allowsFreeze, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            event.charactersIgnoringModifiers?.lowercased() == "f"
        {
            if !event.isARepeat { onFreezeToggle?() }
            return
        }
        switch event.keyCode {
        case 53:  // Escape
            onCancel?()
        case 36, 76:  // Return, keypad Enter: the selection, or the whole display without one
            guard !isFreezing else { return }
            if let rect = committable {
                clearSelection()
                onCommit?(desktopRect(for: rect), display)
            } else {
                onCommit?(display.frame, display)
            }
        case 49:  // Space: choose a window instead, unless a selection is in progress
            if allowsWindowSwitch, !isDragging, held == nil { onSwitchToWindow?() }
        case 123...126 where !event.modifierFlags.contains(.command):
            nudge(event)
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    private func nudge(_ event: NSEvent) {
        guard let rect = committable else { return }
        let direction: NudgeDirection =
            switch event.keyCode {
            case 123: .left
            case 124: .right
            case 125: .down
            default: .up
            }
        held = RegionPrecision.nudged(
            rect, direction, keys: Self.keys(event.modifierFlags), aspect: aspect, within: localBounds,
            minimumSide: RegionSelection.minimumSide)
        selectionDidChange()
    }

    @objc private func aspectChosen(_ sender: NSSegmentedControl) {
        let cases = SelectionAspect.allCases
        guard cases.indices.contains(sender.selectedSegment) else { return }
        aspect = cases[sender.selectedSegment]
        onAspectChange?(aspect)
        window?.makeFirstResponder(self)
    }

    private func resolveDrag() {
        guard let anchor, let pointer else { return }
        drag = RegionPrecision.drag(
            anchor: anchor, pointer: pointer, aspect: aspect, keys: keys, guides: snapGuides(), within: localBounds)
        selectionDidChange()
    }

    private func selectionDidChange() {
        needsDisplay = true
        needsLayout = true
    }

    private var committable: Rect<DisplaySpace>? {
        guard let selection, selection.width >= RegionSelection.minimumSide,
            selection.height >= RegionSelection.minimumSide
        else { return nil }
        return selection
    }

    private static func keys(_ flags: NSEvent.ModifierFlags) -> SelectionKeys {
        SelectionKeys(shift: flags.contains(.shift), option: flags.contains(.option), command: flags.contains(.command))
    }

    private static func title(_ aspect: SelectionAspect) -> String {
        switch aspect {
        case .free: String(localized: "Free")
        case .square: "1:1"
        case .fourByThree: "4:3"
        case .sixteenByNine: "16:9"
        case .threeByTwo: "3:2"
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if let frozenImage {
            drawImage(frozenImage, in: bounds)
        } else if hasShownFrozenFrame {
            NSColor.clear.setFill()
            bounds.fill(using: .copy)
        }
        NSColor.black.withAlphaComponent(reduceTransparency ? 0.5 : 0.3).setFill()
        bounds.fill()

        let lineWidth: CGFloat = highContrast ? 2 : 1
        if let rect = selection.map(Self.cgRect) {
            if let frozenImage {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: rect).addClip()
                drawImage(frozenImage, in: bounds)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                NSColor.clear.setFill()
                rect.fill(using: .copy)
            }
            NSColor.black.setStroke()
            let outer = NSBezierPath(rect: rect.insetBy(dx: -lineWidth, dy: -lineWidth))
            outer.lineWidth = lineWidth
            outer.stroke()
            NSColor.white.setStroke()
            let inner = NSBezierPath(rect: rect)
            inner.lineWidth = lineWidth
            inner.stroke()
        }
        for guide in visibleGuides { drawGuide(guide, lineWidth: lineWidth) }
        drawChip()
        if let frozenImage { drawMagnifier(frozenImage) }

        var lines = [instructions]
        if let freezeInstruction { lines.append(freezeInstruction) }
        if let notice { lines.insert(notice, at: 0) }
        if pointerLeftDisplay {
            lines.append(String(localized: "A selection stays on the display where it started."))
        }
        drawLabel(
            lines.joined(separator: "\n"), anchoredAt: CGPoint(x: bounds.midX, y: bounds.minY + 48), centered: true)
    }

    private func drawImage(_ image: CGImage, in destination: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // Transparent source pixels must never reveal the live desktop behind a frozen panel.
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(destination)
        context.setBlendMode(.normal)
        context.translateBy(x: destination.minX, y: destination.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(origin: .zero, size: destination.size))
        context.restoreGState()
    }

    private func drawMagnifier(_ image: CGImage) {
        guard let pointer = magnifierPointer, bounds.contains(pointer) else { return }
        let side = min(15, image.width, image.height)
        let sourceX = min(image.width - 1, Int((pointer.x - bounds.minX) * Double(image.width) / bounds.width))
        let sourceY = min(image.height - 1, Int((pointer.y - bounds.minY) * Double(image.height) / bounds.height))
        let left = max(0, min(sourceX - side / 2, image.width - side))
        let top = max(0, min(sourceY - side / 2, image.height - side))
        guard let patch = image.cropping(to: CGRect(x: left, y: top, width: side, height: side)) else { return }

        let zoom: CGFloat = 6
        let size = CGFloat(side) * zoom
        let margin: CGFloat = 5
        let offset: CGFloat = 20
        let candidate = pointer.x + offset + size <= bounds.maxX ? pointer.x + offset : pointer.x - offset - size
        let destination = CGRect(
            x: max(bounds.minX + margin, min(candidate, bounds.maxX - size - margin)),
            y: max(bounds.minY + margin, min(pointer.y + offset, bounds.maxY - size - margin)),
            width: size, height: size)
        drawImage(patch, in: destination)
        let sample = CGRect(
            x: destination.minX + CGFloat(sourceX - left) * zoom, y: destination.minY + CGFloat(sourceY - top) * zoom,
            width: zoom, height: zoom)
        NSColor.black.setStroke()
        NSBezierPath(rect: destination.insetBy(dx: -2, dy: -2)).stroke()
        NSBezierPath(rect: sample.insetBy(dx: -1, dy: -1)).stroke()
        NSColor.white.setStroke()
        NSBezierPath(rect: destination.insetBy(dx: -1, dy: -1)).stroke()
        NSBezierPath(rect: sample).stroke()

        let below = destination.maxY + 9
        let labelY = below + 22 <= bounds.maxY ? below : destination.minY - 25
        drawLabel(
            String(localized: "x: \(sourceX) px, y: \(sourceY) px"),
            anchoredAt: CGPoint(x: destination.midX, y: labelY), centered: true)
    }

    /// A white line on a black keyline across the display, like the selection's own border.
    private func drawGuide(_ guide: SnapGuide<DisplaySpace>, lineWidth: CGFloat) {
        let path = NSBezierPath()
        let position = CGFloat(guide.position)
        switch guide.axis {
        case .vertical:
            path.move(to: CGPoint(x: position, y: bounds.minY))
            path.line(to: CGPoint(x: position, y: bounds.maxY))
        case .horizontal:
            path.move(to: CGPoint(x: bounds.minX, y: position))
            path.line(to: CGPoint(x: bounds.maxX, y: position))
        }
        NSColor.black.setStroke()
        path.lineWidth = lineWidth * 3
        path.stroke()
        NSColor.white.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    private struct Chip {
        var background: CGRect
        var text: NSAttributedString?
        var textOrigin: CGPoint
        var control: CGRect
    }

    /// The size label with the aspect control when offered: under the selection's bottom-right corner, or at
    /// the bottom of the display before there is a selection.
    private func chip() -> Chip {
        let control = offersAspect ? aspectControl.intrinsicContentSize : .zero
        let text = selection.map { rect in
            let size = RegionSelection.pixelSize(of: desktopRect(for: rect), on: display)
            return NSAttributedString(
                string: String(localized: "\(size.width) × \(size.height) px"), attributes: Self.labelAttributes)
        }
        let textSize = text?.size() ?? .zero
        let gap = text == nil || !offersAspect ? 0 : DesignTokens.Space.s
        let content = CGSize(width: textSize.width + gap + control.width, height: max(textSize.height, control.height))
        let padding = CGSize(width: DesignTokens.Space.s, height: DesignTokens.Space.xs)
        var origin =
            selection.map(Self.cgRect).map { CGPoint(x: $0.maxX - 4 - content.width, y: $0.maxY + 6 + padding.height) }
            ?? CGPoint(x: bounds.midX - content.width / 2, y: bounds.maxY - 48 - content.height)
        // Keep the chip, with its background, fully inside the display.
        let insetX = 12 + padding.width, insetY = 12 + padding.height
        origin.x = min(max(origin.x, bounds.minX + insetX), bounds.maxX - content.width - insetX)
        origin.y = min(max(origin.y, bounds.minY + insetY), bounds.maxY - content.height - insetY)
        return Chip(
            background: CGRect(origin: origin, size: content).insetBy(dx: -padding.width, dy: -padding.height),
            text: text, textOrigin: CGPoint(x: origin.x, y: origin.y + (content.height - textSize.height) / 2),
            control: CGRect(
                x: origin.x + textSize.width + gap, y: origin.y + (content.height - control.height) / 2,
                width: control.width, height: control.height))
    }

    private func drawChip() {
        let chip = chip()
        guard chip.text != nil || offersAspect else { return }
        NSColor.black.withAlphaComponent(0.75).setFill()
        let radius = DesignTokens.Radius.control
        NSBezierPath(roundedRect: chip.background, xRadius: radius, yRadius: radius).fill()
        chip.text?.draw(at: chip.textOrigin)
    }

    private func drawLabel(_ text: String, anchoredAt point: CGPoint, centered: Bool) {
        let string = NSAttributedString(string: text, attributes: Self.labelAttributes)
        let textSize = string.boundingRect(
            with: CGSize(width: min(bounds.width - 40, 640), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).size
        var origin = point
        if centered { origin.x -= textSize.width / 2 }
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

    /// The view's own points, which cover exactly this display.
    private var localBounds: Rect<DisplaySpace> {
        Rect(x: 0, y: 0, width: bounds.width, height: bounds.height)
    }

    private func localPoint(_ point: CGPoint) -> Point<DisplaySpace> {
        Point(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private static func cgRect(_ rect: Rect<DisplaySpace>) -> CGRect {
        CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    /// Desktop points per view point; 1 while the window covers exactly this display.
    private var scale: (x: Double, y: Double) {
        (
            bounds.width > 0 ? display.frame.width / bounds.width : 1,
            bounds.height > 0 ? display.frame.height / bounds.height : 1
        )
    }

    /// The display's edges and every listed window frame, in view points.
    private func snapGuides() -> [SnapGuide<DisplaySpace>] {
        let scale = scale
        let frames = snapFrames.map { frame in
            Rect<DisplaySpace>(
                x: (frame.minX - display.frame.minX) / scale.x, y: (frame.minY - display.frame.minY) / scale.y,
                width: frame.width / scale.x, height: frame.height / scale.y)
        }
        return RegionPrecision.guides(within: localBounds, frames: frames)
    }

    /// View points (flipped, top-left) → desktop points.
    private func desktopRect(for rect: Rect<DisplaySpace>) -> Rect<DesktopSpace> {
        let scale = scale
        return Rect(
            x: display.frame.minX + rect.minX * scale.x, y: display.frame.minY + rect.minY * scale.y,
            width: rect.width * scale.x, height: rect.height * scale.y)
    }

    private var instructions: String {
        allowsWindowSwitch
            ? String(
                localized:
                    "Drag to select an area, or press Space to choose a window. Press Return to capture the whole display or Escape to cancel."
            )
            : String(
                localized:
                    "Drag to select an area. Press Return to capture the whole display or Escape to cancel.")
    }

    private var accessibilityInstructions: String {
        [notice, instructions, freezeInstruction].compactMap { $0 }.joined(separator: "\n")
    }

    private var freezeInstruction: String? {
        guard allowsFreeze else { return nil }
        if isFreezing { return String(localized: "Freezing the display… Press F to return to live selection.") }
        if frozenImage != nil { return String(localized: "Display frozen. Press F to return to live selection.") }
        return String(localized: "Press F to freeze this display and use the magnifier.")
    }
}

/// A click on another display's overlay picks a ratio at once, without first making it key.
private final class AspectControl: NSSegmentedControl {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
