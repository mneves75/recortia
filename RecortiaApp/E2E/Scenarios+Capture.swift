#if DEBUG
    import AppKit
    import Domain
    import Features
    import Imaging
    import MacPlatform
    import RecortiaFixtures
    import SwiftUI

    /// Capture UI and capture → editor through `CaptureCoordinator` with the synthetic source (FR-02).
    @MainActor
    enum CaptureScenarios {
        /// The region overlay's real selection view over the synthetic desktop, driven by synthetic
        /// mouse events; the commit goes to the coordinator exactly as `CaptureUIController` wires it.
        static func regionOverlay(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let coordinator = harness.features.capture
            let display = harness.capture.display
            harness.app.perform(.captureRegion)
            try context.require(
                "Capture Region starts selecting", coordinator.state == .selecting, "\(coordinator.state)")
            context.check(
                "the coordinator offers the synthetic display for region selection",
                coordinator.selectionContext == .region([display]),
                "\(String(describing: coordinator.selectionContext))")

            let size = SyntheticDesktop.size
            let selection = RegionSelectionView(display: display)
            let window = E2ESnapshot.host(nsView: selection, size: size)
            defer { window.close() }

            var committed: (Rect<DesktopSpace>, DisplayInfo)?
            selection.onCommit = { rect, display in
                committed = (rect, display)
                coordinator.commitRegion(rect, on: display)
            }
            let start = CGPoint(x: 180, y: 120), end = CGPoint(x: 870, y: 590)
            let before = harness.editors.controllers.count
            selection.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: selection))
            for p in E2EActions.interpolate(
                Point(x: start.x, y: start.y), Point(x: end.x, y: end.y), count: 5)
            {
                selection.mouseDragged(
                    with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: p.x, y: p.y), in: selection))
            }
            let expected = Rect<DesktopSpace>(
                x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y)
            let pixels = RegionSelection.pixelSize(of: expected, on: display)
            context.check(
                "the size label reports display pixels, not points", pixels == PixelSize(width: 1380, height: 940),
                "\(pixels.width) × \(pixels.height) px")
            await E2ESnapshot.settle(selection)
            let lightDrag = context.snapshot(selection, shot: "dragging", over: harness.desktop)
            await context.darkOverlay(selection, in: window, shot: "dragging", over: harness.desktop, light: lightDrag)

            selection.mouseUp(with: try mouseEvent(.leftMouseUp, at: end, in: selection))
            let commit = try context.unwrap("mouse up commits the selection", committed)
            context.check("committed rect is the dragged area in desktop points", commit.0 == expected, "\(commit.0)")
            context.check("committed on the display where the drag started", commit.1 == display)
            let controller = try await E2EActions.waitForNewEditor(harness, after: before, context)
            let geometry = try context.unwrap("capture carries geometry", capturedGeometry(controller.model))
            context.check(
                "capture bounds equal the selection", geometry.desktopBounds == expected, "\(geometry.desktopBounds)")
        }

        static func windowChooser(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let coordinator = harness.features.capture
            harness.app.perform(.captureWindow)
            try context.require(
                "Capture Window starts selecting", coordinator.state == .selecting, "\(coordinator.state)")
            context.check(
                "windows load asynchronously", coordinator.selectionContext == .loadingWindows,
                "\(String(describing: coordinator.selectionContext))")
            let loading = HostingPanel(title: "", activating: true)
            loading.setContent(WindowChooserView(windows: nil, onChoose: { _ in }, onCancel: {}))
            E2ESnapshot.park(loading)
            defer { loading.close() }
            if let root = loading.contentView {
                await E2ESnapshot.settle(root)
                context.snapshot(root, shot: "loading")
                await context.darkCompanion(root, in: loading, shot: "loading", surface: "window chooser loading")
            }

            let listed = await E2EWait.until {
                if case .window = coordinator.selectionContext { return true }
                return false
            }
            try context.require(
                "the window list arrives", listed, "\(String(describing: coordinator.selectionContext))")
            guard case .window(let windows)? = coordinator.selectionContext else { throw E2EAbort("no window list") }
            // `CaptureUIController` reuses one panel for loading and the list and positions it in
            // `present` right after `setContent`, from whatever size the frame has then. Repeat that
            // arithmetic on the parked panel: once the list's size arrives, the top edge and the
            // horizontal centre must still be where `present` put them.
            let top = loading.frame.maxY
            let centre = loading.frame.midX
            let loadingSize = loading.frame.size
            loading.setContent(WindowChooserView(windows: windows, onChoose: { _ in }, onCancel: {}))
            loading.sizeToContentIfUnsized()
            let immediate = loading.frame.size
            loading.setFrameOrigin(CGPoint(x: centre - immediate.width / 2, y: top - immediate.height))
            if let swapped = loading.contentView { await E2ESnapshot.settle(swapped) }
            let settled = loading.frame
            context.check(
                "the reused chooser panel keeps its top edge and centre when the list replaces loading",
                abs(settled.maxY - top) <= 1 && abs(settled.midX - centre) <= 1,
                "loading \(loadingSize), right after setContent \(immediate), settled \(settled.size); "
                    + "top \(top) to \(settled.maxY), centre \(centre) to \(settled.midX)")
            context.check(
                "the chooser lists every synthetic window", windows == harness.capture.windowList,
                windows.map(\.ownerName).joined(separator: ", "))

            var chosenWindows: [WindowInfo] = []
            let panel = HostingPanel(title: "", activating: true)
            panel.setContent(
                WindowChooserView(
                    windows: windows,
                    onChoose: {
                        chosenWindows.append($0)
                        coordinator.commitSelection(.window($0))  // as `CaptureUIController` wires it
                    }, onCancel: { coordinator.cancel() }))
            E2ESnapshot.park(panel)
            defer { panel.close() }
            let root = try context.unwrap("chooser panel has content", panel.contentView)
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "list")
            await context.darkCompanion(root, in: panel, shot: "list", surface: "window chooser list")

            // Drive the chooser's own controls: select the second row in the hosted list, then
            // send Return as a key equivalent, which fires the default "Capture" button. `onChoose` must receive the
            // selected row's window, not the first one and not a value this scenario assigned.
            checkChooserFits(root, rows: windows.count, label: "the synthetic windows", scrolls: false, context)
            let many = (1...12).map {
                WindowInfo(
                    id: CGWindowID(9000 + $0), ownerName: "Synthetic App \($0)", ownerPID: pid_t(9000 + $0),
                    title: $0.isMultiple(of: 3) ? nil : "Document \($0)",
                    frame: Rect(x: 0, y: 0, width: 400, height: 300), displayID: harness.capture.display.id)
            }
            let long = HostingPanel(title: "", activating: true)
            long.setContent(WindowChooserView(windows: many, onChoose: { _ in }, onCancel: {}))
            E2ESnapshot.park(long)
            if let longRoot = long.contentView {
                await E2ESnapshot.settle(longRoot)
                checkChooserFits(longRoot, rows: many.count, label: "twelve windows", scrolls: true, context)
                context.snapshot(longRoot, shot: "long-list")
            }
            long.close()

            let table = try context.unwrap(
                "the chooser hosts its window list", EditorWindowController.first(NSTableView.self, in: root))
            try context.require(
                "the list has one row per window", table.numberOfRows == windows.count,
                "rows=\(table.numberOfRows); windows=\(windows.count)")
            let window = try context.unwrap("a second window exists to select", windows.dropFirst().first)
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            await E2ESnapshot.settle(root)
            context.check("nothing is chosen before Capture is pressed", chosenWindows.isEmpty, "\(chosenWindows)")
            let before = harness.editors.controllers.count
            let returnKey = try CaptureVisibilityScenarios.keyEvent(
                36, characters: "\r", windowNumber: panel.windowNumber)
            context.check("the panel handles Return as a key equivalent", panel.performKeyEquivalent(with: returnKey))
            await E2ESnapshot.settle(root)
            context.check(
                "pressing Capture chooses exactly the selected row's window", chosenWindows == [window],
                "chosen=\(chosenWindows.map(\.ownerName)); expected=\(window.ownerName)")
            let controller = try await E2EActions.waitForNewEditor(harness, after: before, context)
            let geometry = try context.unwrap("capture carries geometry", capturedGeometry(controller.model))
            context.check(
                "geometry names the chosen window",
                geometry.source == .window(id: window.id, displayID: window.displayID),
                "\(geometry.source)")
            context.check(
                "image covers the window at 2×",
                geometry.pixelSize
                    == PixelSize(width: Int(window.frame.width * 2), height: Int(window.frame.height * 2)),
                "\(geometry.pixelSize.width) × \(geometry.pixelSize.height)")
        }

        static func countdown(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let coordinator = harness.features.capture
            harness.settings.update { $0.captureDelaySeconds = 3 }
            defer { harness.settings.update { $0.captureDelaySeconds = 0 } }
            context.check("Capture with Delay uses the configured 3 s", coordinator.delayForDelayedCapture == 3)
            harness.app.perform(.captureWithDelay)
            try context.require(
                "Capture with Delay starts selecting", coordinator.state == .selecting, "\(coordinator.state)")
            let before = harness.editors.controllers.count
            let capturesBefore = harness.capture.captures.count
            let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
            try context.require(
                "region committed", coordinator.commitRegion(E2EActions.desktopRect(rect), on: harness.capture.display))
            context.check(
                "the countdown starts at 3", coordinator.state == .countdown(remaining: 3), "\(coordinator.state)")

            // The countdown HUD rendered from the live coordinator state. The real presenter hosts it
            // in a `HostingPanel`; that combination is probed in a child process below because it
            // can end the process with an AppKit exception.
            let hud = E2ESnapshot.host(CountdownFollower(coordinator: coordinator))
            let root = try context.unwrap("countdown HUD has content", hud.contentView)
            await E2ESnapshot.settle(root, for: .milliseconds(150))
            context.snapshot(root)
            await context.darkHosted(
                CountdownFollower(coordinator: coordinator), light: root, shot: nil, surface: "countdown",
                settle: .milliseconds(150))
            hud.close()
            context.check(
                "nothing is captured during the countdown", harness.capture.captures.count == capturesBefore,
                "\(harness.capture.captures.count - capturesBefore) captures")
            // Exercise the cancellation action without taking the host's global Escape key.
            // Carbon registration itself belongs to the explicitly approved live-desktop check.
            coordinator.cancel()
            context.check("Cancel ends the countdown", coordinator.state == .canceled, "\(coordinator.state)")
            context.check("Cancel captures nothing", harness.capture.captures.count == capturesBefore)
            harness.app.perform(.captureWithDelay)
            try context.require(
                "a new countdown can start after Cancel",
                coordinator.commitRegion(E2EActions.desktopRect(rect), on: harness.capture.display))

            var seen: [Int] = []
            let finished = await E2EWait.until(timeout: .seconds(8), poll: .milliseconds(50)) {
                if case .countdown(let remaining) = coordinator.state, seen.last != remaining { seen.append(remaining) }
                return harness.editors.controllers.count > before
            }
            try context.require("the capture runs after the countdown", finished, "\(coordinator.state)")
            context.check("the countdown ticks 3, 2, 1", seen == [3, 2, 1], "\(seen)")
            context.check(
                "exactly one capture ran", harness.capture.captures.count == capturesBefore + 1,
                "\(harness.capture.captures.count - capturesBefore)")
            await E2EPanelProbe.check(.countdown, context)
        }

        static func captureToEditor(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let rect = CGRect(x: 0, y: 0, width: 700, height: 500)
            let controller = try await E2EActions.captureRegion(harness, rect, context)
            let model = controller.model
            context.check("the coordinator reports editing", harness.features.capture.state == .editing)
            context.check("Repeat Last Region becomes available", harness.app.isEnabled(.repeatLastRegion))
            let geometry = try context.unwrap("capture carries geometry", capturedGeometry(model))
            context.check(
                "geometry source is a region on the synthetic display",
                geometry.source == .region(displayID: harness.capture.display.id), "\(geometry.source)")
            context.check(
                "geometry bounds equal the selection", geometry.desktopBounds == E2EActions.desktopRect(rect),
                "\(geometry.desktopBounds)")
            context.check("point-to-pixel scale is 2", geometry.pointPixelScale == 2, "\(geometry.pointPixelScale)")
            context.check(
                "pixel size is 1400 × 1000", geometry.pixelSize == PixelSize(width: 1400, height: 1000),
                "\(geometry.pixelSize)")
            context.check(
                "canvas matches the captured pixels", model.document.canvasSize == Size(width: 1400, height: 1000),
                "\(model.document.canvasSize)")
            context.check("measurements know the capture scale", model.measurementPointScale == 2)

            let base = try context.unwrap("sanitized base rendered", model.baseImage)
            let rendered = try E2EActions.pixels(of: base, "base", context)
            let source = try context.unwrap(
                "synthetic source crop",
                harness.desktop.cropping(to: CGRect(x: 0, y: 0, width: 1400, height: 1000)))
            let expected = try E2EActions.pixels(of: source, "source crop", context)
            context.check(
                "editor base equals the captured desktop pixels", rendered == expected,
                "differs in \(zip(rendered.bytes, expected.bytes).filter { $0 != $1 }.count) bytes")
            let marker = rendered.pixel(x: 20, y: 20)
            context.check(
                "corner marker 1 is at the top-left",
                E2EActions.distance(marker, E2EActions.color(SyntheticDesktop.markerColors[0])) <= 1, marker.hex)
            await E2EActions.snapshotEditor(controller, context)
            await E2EActions.darkEditor(controller, context, shot: nil, surface: "editor, Image tab")
        }

        /// The chooser's list is as tall as its rows up to the maximum: the last row ends within a
        /// few points of the visible bottom (no empty band), and only a list over the maximum scrolls.
        private static func checkChooserFits(
            _ root: NSView, rows: Int, label: String, scrolls: Bool, _ context: ScenarioContext
        ) {
            root.layoutSubtreeIfNeeded()
            guard let table = EditorWindowController.first(NSTableView.self, in: root),
                let scroll = table.enclosingScrollView, table.numberOfRows == rows, rows > 0
            else {
                context.check("\(label): the chooser hosts a table with \(rows) rows", false)
                return
            }
            let visible = scroll.contentView.bounds.height
            let document = scroll.documentView?.frame.height ?? 0
            let lastRow = table.rect(ofRow: rows - 1).maxY
            E2ERunner.log(
                "chooser \(label): visible \(visible), document \(document), last row ends \(lastRow), rows "
                    + (0..<rows).map { "\(table.rect(ofRow: $0).height)" }.joined(separator: " "))
            if scrolls {
                context.check(
                    "\(label): the list stops at its maximum and scrolls",
                    abs(scroll.frame.height - WindowChooserView.maximumListHeight) <= 1 && document > visible + 1,
                    "list \(scroll.frame.height), visible \(visible), document \(document)")
            } else {
                context.check(
                    "\(label): every row is visible without scrolling", document <= visible + 1,
                    "visible \(visible), document \(document)")
                context.check(
                    "\(label): no empty band under the last row", visible - lastRow <= 12,
                    "visible \(visible), last row ends \(lastRow)")
            }
        }

        static func capturedGeometry(_ model: EditorModel) -> CaptureGeometry? {
            guard model.document.assets.count == 1,
                case .captured(let geometry)? = model.document.assets.values.first?.origin
            else { return nil }
            return geometry
        }

        static func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) throws -> NSEvent {
            let location = view.convert(point, to: nil)
            guard let window = view.window,
                let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { throw E2EAbort("could not synthesize \(type) event") }
            return event
        }
    }

    /// Follows the coordinator like the app's private countdown view.
    private struct CountdownFollower: View {
        let coordinator: CaptureCoordinator

        var body: some View {
            if case .countdown(let remaining) = coordinator.state {
                CountdownView(remaining: remaining, onCancel: { coordinator.cancel() })
            }
        }
    }
#endif
