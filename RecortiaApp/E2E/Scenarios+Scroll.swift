#if DEBUG
    import AppKit
    import Domain
    import Features
    import Imaging
    import MacPlatform
    import RecortiaFixtures
    import SwiftUI

    /// Scrolling capture with synthetic frames through the real stitcher and `ScrollSessionModel`
    /// (FR-10, SCR-01).
    @MainActor
    enum ScrollScenarios {
        /// Waits for the discard question on `window` and answers it: a sheet on that review window,
        /// never an app alert, with the existing wording; `shot` also records it in light and dark.
        static func answerDiscardSheet(
            on window: NSWindow, discard: Bool, _ harness: E2EHarness, _ context: ScenarioContext,
            shot: String? = nil
        ) async throws {
            let alerts = harness.messages.alerts.count
            let questions = harness.quit.questions.count
            let sheet = try context.unwrap(
                "the discard question is a sheet on the review window",
                await E2EWait.until(timeout: .seconds(5)) { window.attachedSheet != nil } ? window.attachedSheet : nil)
            let content = try context.unwrap("the discard sheet has content", sheet.contentView)
            let texts = EditorWindowController.all(NSTextField.self, in: content).map(\.stringValue)
            context.check(
                "the discard sheet is attached to its review window and is not an alert",
                sheet.sheetParent === window && harness.messages.alerts.count == alerts
                    && harness.quit.questions.count == questions)
            context.check(
                "the discard sheet keeps its wording",
                texts.contains(String(localized: "Discard this scrolling capture?")), texts.joined(separator: " | "))
            if let shot {
                await E2ESnapshot.settle(content)
                context.snapshot(content, shot: "\(shot)-sheet")
                await context.darkCompanion(content, in: sheet, shot: "\(shot)-sheet", surface: "discard sheet")
            }
            window.endSheet(sheet, returnCode: discard ? .alertFirstButtonReturn : .alertSecondButtonReturn)
        }

        static func automaticTarget(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            // Accessibility is granted synthetically here, so the live scroller would post events to
            // whatever window the target names, including one of the host Mac's own.
            context.check(
                "the harness scroller posts no system events",
                harness.services.autoScroller is SyntheticAutoScroll,
                String(describing: type(of: harness.services.autoScroller)))
            for check in await AutoScrollRegression.run() {
                context.check(check.name, check.passed)
            }
        }

        static func scrolling(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let model = harness.features.scroll
            let permissionRequestsBefore = harness.permission.requestCount
            let fixture = ScrollPageFixture(
                seed: 0xE2E5, kind: .text, width: 480, viewportHeight: 360, pageHeight: 2400)
            let offsets = fixture.forwardOffsets(steps: 90...170)
            let frames = offsets.enumerated().compactMap { fixture.frame(offset: $0.element, index: $0.offset) }
            try context.require("all fixture frames render", frames.count == offsets.count)
            harness.scrollFrames.load(frames, holdAfter: frames.count / 2)

            try context.require("the session begins", await model.begin(), "\(model.state)")
            context.check(
                "no permission prompt with access granted", harness.permission.requestCount == permissionRequestsBefore,
                "before=\(permissionRequestsBefore), after=\(harness.permission.requestCount), delta=\(harness.permission.requestCount - permissionRequestsBefore)"
            )
            let display = harness.capture.display
            let region = Rect<DesktopSpace>(x: 300, y: 160, width: 240, height: 180)
            model.chooseTarget(.region(region, display: display))
            context.check("choosing the area arms the session", model.state == .armed, "\(model.state)")
            context.check("manual mode without automatic scrolling", model.mode == .manual)
            model.start()

            let held = await E2EWait.until(timeout: .seconds(20)) {
                harness.scrollFrames.isHolding && model.acceptedFrames > 0 && model.state == .collecting
                    && harness.scrollFrames.deliveredCount == frames.count / 2
            }
            try context.require("frames are collected", held, "state \(model.state), accepted \(model.acceptedFrames)")
            _ = await E2EWait.until(timeout: .seconds(5)) { model.outputSize.height > fixture.viewportHeight }
            // The product's own panel, so its title-bar behavior is what the screenshot shows.
            let hud = ScrollUIController.makeHUDPanel()
            hud.setContent(HUDFollower(model: model))
            E2ESnapshot.park(hud)
            defer { hud.close() }
            let hudRoot = try context.unwrap("HUD has content", hud.contentView)
            await E2ESnapshot.settle(hudRoot)
            context.snapshot(hudRoot, shot: "hud")
            checkHUDPanel(hud, model: model, context)
            await context.darkCompanion(hudRoot, in: hud, shot: "hud", surface: "scrolling HUD")

            harness.scrollFrames.release()
            let drained = await E2EWait.until(timeout: .seconds(30)) {
                harness.scrollFrames.isExhausted && harness.scrollFrames.isHolding
            }
            try context.require(
                "every frame was offered", drained, "\(harness.scrollFrames.deliveredCount)/\(frames.count)")
            // Relative: earlier scenarios (last-window's scroll review) stop their own sessions.
            let stopsBefore = harness.scrollFrames.stopCount
            model.stop()
            context.check("Stop opens the review", model.state == .reviewing, "\(model.state)")
            context.check(
                "the stream was stopped once", harness.scrollFrames.stopCount == stopsBefore + 1,
                "\(harness.scrollFrames.stopCount - stopsBefore) stops")
            let expected = fixture.expectedOutput(lastOffset: offsets.last ?? 0)
            context.check(
                "stitched size equals the page",
                model.outputSize == PixelSize(width: expected.width, height: expected.height),
                "\(model.outputSize.width) × \(model.outputSize.height), expected \(expected.width) × \(expected.height)"
            )
            context.check("the result is complete, not partial", !model.isPartial)
            context.check(
                "the review marks one seam per join", model.seams.count == model.acceptedFrames - 1,
                "\(model.seams.count) seams, \(model.acceptedFrames) accepted frames")
            _ = await E2EWait.until(timeout: .seconds(10)) { model.preview != nil }

            let review = NSWindow(contentViewController: NSHostingController(rootView: ReviewFollower(model: model)))
            review.styleMask = [.titled]
            review.isReleasedWhenClosed = false
            E2ESnapshot.park(review)
            defer { review.close() }
            let reviewRoot = try context.unwrap("review has content", review.contentView)
            await E2ESnapshot.settle(reviewRoot)
            context.snapshot(reviewRoot, shot: "review")
            // The stitched preview is user content; everything around it is the review's chrome.
            let previewArea = try context.unwrap(
                "the review's preview is in a scroll view",
                EditorWindowController.first(NSScrollView.self, in: reviewRoot))
            await context.darkCompanion(
                reviewRoot, in: review, shot: "review", surface: "scrolling review", excluding: [previewArea])

            // A declined discard must leave the assembled stitch where it is: this is the only
            // place the model is really in `.reviewing`, so the survival claim is proved here.
            let discardGate = ScrollUIController(model: model, displays: { [] })
            let gateWindow = try context.unwrap(
                "the discard gate shows its review window",
                await E2EWait.until { NSApp.windows.contains { $0.delegate === discardGate } }
                    ? NSApp.windows.first { $0.delegate === discardGate } : nil)
            gateWindow.ignoresMouseEvents = true
            discardGate.requestDiscard()
            try await answerDiscardSheet(on: gateWindow, discard: false, harness, context)
            context.check(
                "a declined discard leaves the stitched capture in review", model.state == .reviewing,
                "\(model.state)")

            try await checkCountWording(context)

            let before = harness.editors.controllers.count
            await model.accept()
            let controller = try await E2EActions.waitForNewEditor(harness, after: before, context)
            let asset = try context.unwrap("stitched asset", controller.model.document.assets.values.first)
            let complete = if case .scrollCapture(partialReason: nil, _) = asset.origin { true } else { false }
            context.check("the asset is a complete scroll capture", complete, "\(asset.origin)")
            let base = try context.unwrap("stitched image", controller.model.baseImage)
            let stitched = try E2EActions.pixels(of: base, "stitched", context)
            let badRows = compare(stitched, expected, fixture: fixture)
            context.check(
                "every stitched row equals the page row in order (no missing or duplicated rows)", badRows.isEmpty,
                badRows.isEmpty ? "\(stitched.height) rows" : "\(badRows.count) bad rows, first: \(badRows.prefix(8))")
        }

        /// Output rows whose pixels differ from the expected page row at the same position (beyond
        /// the fixture's ±1 noise), ignoring the animated spinner and caret. Row-for-row equality
        /// with the ideal page means no row is missing, duplicated, or out of order.
        static func compare(_ actual: DecodedPixels, _ expected: ScrollPageBuffer, fixture: ScrollPageFixture) -> [Int]
        {
            guard actual.width == expected.width, actual.height == expected.height else { return [-1] }
            var bad: [Int] = []
            for y in 0..<actual.height {
                var rowOK = true
                for x in 0..<actual.width where !fixture.isAnimated(outputX: x, outputY: y) {
                    let i = (y * actual.width + x) * 4
                    for c in 0..<3 where abs(Int(actual.bytes[i + c]) - Int(expected.pixels[i + c])) > 3 {
                        rowOK = false
                    }
                    if !rowOK { break }
                }
                if !rowOK { bad.append(y) }
            }
            return bad
        }
    }

    extension ScrollScenarios {
        /// B-9b: a page that scrolls to the right, chosen with the HUD's direction control before
        /// Start, through the real stitcher: the result is as wide as the page, every column in
        /// order, with one seam per join drawn as a vertical band, and the review scrolls sideways.
        static func horizontal(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let model = harness.features.scroll
            let choice = harness.settings.preferences.scrollCaptureDirectionChoice
            defer { harness.settings.update { $0.scrollCaptureDirectionChoice = choice } }
            harness.settings.update { $0.scrollCaptureDirectionChoice = nil }
            // The vertical fixture transposed: a 420 × 300 viewport over a page 1,800 columns wide
            // with fixed columns at the left and right.
            let fixture = ScrollPageFixture(
                seed: 0xE2E6, kind: .text, width: 300, viewportHeight: 420, pageHeight: 1800)
            let offsets = fixture.forwardOffsets(steps: 90...170)
            let frames = offsets.enumerated().compactMap {
                fixture.horizontalFrame(offset: $0.element, index: $0.offset)
            }
            try context.require("all horizontal fixture frames render", frames.count == offsets.count)
            harness.scrollFrames.load(frames, holdAfter: nil)

            try context.require("the session begins", await model.begin(), "\(model.state)")
            let region = Rect<DesktopSpace>(x: 300, y: 160, width: 210, height: 150)
            model.chooseTarget(.region(region, display: harness.capture.display))
            try context.require("choosing the area arms the session", model.state == .armed, "\(model.state)")
            context.check("a new session is vertical by default", model.direction == .vertical)

            let hud = ScrollUIController.makeHUDPanel()
            hud.setContent(HUDFollower(model: model))
            E2ESnapshot.park(hud)
            defer { hud.close() }
            let hudRoot = try context.unwrap("HUD has content", hud.contentView)
            await E2ESnapshot.settle(hudRoot)
            let directions = [String(localized: "Vertical"), String(localized: "Horizontal")]
            let control = try context.unwrap(
                "the armed HUD offers Vertical and Horizontal",
                EditorWindowController.all(NSSegmentedControl.self, in: hudRoot).first { control in
                    control.segmentCount == directions.count
                        && (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" } == directions
                })
            context.check(
                "the direction control starts on Vertical", control.selectedSegment == 0, "\(control.selectedSegment)")
            control.setSelected(true, forSegment: 1)
            try context.require(
                "the direction control sends its action", control.sendAction(control.action, to: control.target))
            context.check(
                "choosing Horizontal sets the session and remembers it",
                model.direction == .horizontal && harness.settings.preferences.scrollCaptureDirection == .horizontal,
                "\(model.direction), stored \(harness.settings.preferences.scrollCaptureDirection)")
            await E2ESnapshot.settle(hudRoot)
            context.snapshot(hudRoot, shot: "hud-horizontal")
            await context.darkCompanion(hudRoot, in: hud, shot: "hud-horizontal", surface: "armed scrolling HUD")

            model.start()
            let drained = await E2EWait.until(timeout: .seconds(30)) {
                harness.scrollFrames.isExhausted && harness.scrollFrames.isHolding && model.acceptedFrames > 0
            }
            try context.require(
                "every frame was offered", drained, "\(harness.scrollFrames.deliveredCount)/\(frames.count)")
            model.stop()
            try context.require("Stop opens the review", model.state == .reviewing, "\(model.state)")
            let expected = fixture.expectedHorizontalOutput(lastOffset: offsets.last ?? 0)
            context.check(
                "stitched width equals the page",
                model.outputSize == PixelSize(width: expected.width, height: expected.height),
                "\(model.outputSize.width) × \(model.outputSize.height), expected \(expected.width) × \(expected.height)"
            )
            context.check("the result is complete, not partial", !model.isPartial)
            context.check(
                "one seam per join, each a column inside the stitch, left to right",
                model.seams.count == model.acceptedFrames - 1 && model.seams == model.seams.sorted()
                    && (model.seams.last ?? 0) < model.outputSize.width,
                "\(model.seams.count) seams, \(model.acceptedFrames) accepted frames, last \(model.seams.last ?? -1)")
            _ = await E2EWait.until(timeout: .seconds(10)) { model.preview != nil }
            let preview = try context.unwrap("the review has a preview", model.preview)
            context.check(
                "the preview is wide and no wider than its bound",
                preview.width > preview.height && preview.width <= 2_000, "\(preview.width) × \(preview.height)")

            let review = NSWindow(contentViewController: NSHostingController(rootView: ReviewFollower(model: model)))
            review.styleMask = [.titled]
            review.isReleasedWhenClosed = false
            E2ESnapshot.park(review)
            defer { review.close() }
            let reviewRoot = try context.unwrap("review has content", review.contentView)
            await E2ESnapshot.settle(reviewRoot)
            context.snapshot(reviewRoot, shot: "review-horizontal")
            let previewArea = try context.unwrap(
                "the review's preview is in a scroll view",
                EditorWindowController.first(NSScrollView.self, in: reviewRoot))
            let documentWidth = previewArea.documentView?.frame.width ?? 0
            context.check(
                "the wide preview fits the review's height and scrolls sideways",
                documentWidth > previewArea.frame.width,
                "content \(documentWidth) pt in a \(previewArea.frame.width) pt viewport")
            await context.darkCompanion(
                reviewRoot, in: review, shot: "review-horizontal", surface: "horizontal scrolling review",
                excluding: [previewArea])

            let before = harness.editors.controllers.count
            await model.accept()
            let controller = try await E2EActions.waitForNewEditor(harness, after: before, context)
            let base = try context.unwrap("stitched image", controller.model.baseImage)
            let stitched = try E2EActions.pixels(of: base, "stitched", context)
            let badColumns = compareColumns(stitched, expected, fixture: fixture)
            context.check(
                "every stitched column equals the page column in order (no missing or repeated columns)",
                badColumns.isEmpty,
                badColumns.isEmpty
                    ? "\(stitched.width) columns" : "\(badColumns.count) bad columns, first: \(badColumns.prefix(8))")
        }
    }

    extension ScrollScenarios {
        /// `compare` for a horizontal stitch: output columns whose pixels differ from the expected
        /// page column. The fixture animates in its vertical orientation, so (x, y) is its (y, x).
        static func compareColumns(
            _ actual: DecodedPixels, _ expected: ScrollPageBuffer, fixture: ScrollPageFixture
        ) -> [Int] {
            guard actual.width == expected.width, actual.height == expected.height else { return [-1] }
            var bad: [Int] = []
            for x in 0..<actual.width {
                var columnOK = true
                for y in 0..<actual.height where !fixture.isAnimated(outputX: y, outputY: x) {
                    let i = (y * actual.width + x) * 4
                    for c in 0..<3 where abs(Int(actual.bytes[i + c]) - Int(expected.pixels[i + c])) > 3 {
                        columnOK = false
                    }
                    if !columnOK { break }
                }
                if !columnOK { bad.append(x) }
            }
            return bad
        }
    }

    /// Mirrors the app's private HUD adapter over `ScrollSessionModel`.
    /// The HUD panel keeps its focus, level and Space contract, and reserves no title-bar band:
    /// its content is exactly as tall as the HUD view hosted alone.
    @MainActor
    private func checkHUDPanel(_ hud: HostingPanel, model: ScrollSessionModel, _ context: ScenarioContext) {
        context.check(
            "the HUD panel stays a titled, full-size-content, non-activating panel",
            hud.styleMask == [.titled, .fullSizeContentView, .nonactivatingPanel], "\(hud.styleMask.rawValue)")
        context.check("the HUD panel floats", hud.level == .floating && hud.isFloatingPanel, "\(hud.level.rawValue)")
        context.check(
            "the HUD panel joins all Spaces", hud.collectionBehavior == SpacePolicy.joinsAllSpaces,
            "\(hud.collectionBehavior.rawValue)")
        context.check("the HUD panel can become key on a click", hud.canBecomeKey)
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
            hud.standardWindowButton($0).map { "\($0.isHidden ? "hidden" : "shown")/\($0.isEnabled ? "on" : "off")" }
                ?? "none"
        }
        let content = hud.contentRect(forFrameRect: hud.frame).height
        let bare = NSHostingView(rootView: HUDFollower(model: model)).fittingSize.height
        context.check(
            "the HUD reserves no empty band above its title", abs(content - bare) <= 1,
            "panel content \(content) pt, HUD alone \(bare) pt; window buttons \(buttons)")
    }

    extension ScrollScenarios {
        /// Review R3-D19: the HUD's progress line and the preview's accessibility label, as rendered,
        /// for one and two in the run's language ("1 frames" and "1 junções" read wrong).
        private static func checkCountWording(_ context: ScenarioContext) async throws {
            let portuguese = context.output.language.hasPrefix("pt")
            let preview = try E2EDrawing.image(size: CGSize(width: 40, height: 80), scale: 1) { rect in
                NSColor.gray.setFill()
                rect.fill()
            }
            for count in [1, 2] {
                let hud = E2ESnapshot.host(
                    ScrollHUDView(
                        hud: ScrollHUDState(
                            source: "", state: .collecting, mode: .manual, notice: nil, acceptedFrames: count,
                            outputLength: 480),
                        onStart: {}, onPause: {}, onResume: {}, onStop: {}, onCancel: {}))
                defer { hud.close() }
                let hudRoot = try context.unwrap("HUD hosted", hud.contentView)
                await E2ESnapshot.settle(hudRoot)
                // The hosted SwiftUI text exposes no accessible value here, so the wording is checked
                // through the same catalog key the view's Text resolves.
                let progress = String(localized: "\(count) frames · \(480) pixels tall")
                let expectedProgress =
                    switch (portuguese, count) {
                    case (false, 1): "1 frame · 480 pixels tall"
                    case (false, _): "2 frames · 480 pixels tall"
                    case (true, 1): "1 quadro · 480 pixels de altura"
                    case (true, _): "2 quadros · 480 pixels de altura"
                    }
                context.check("the HUD reads \(count) frame(s) correctly", progress == expectedProgress, progress)

                let review = E2ESnapshot.host(
                    ScrollReviewView(
                        preview: preview, outputSize: PixelSize(width: 40, height: 80),
                        seams: Array(stride(from: 20, through: 20 * count, by: 20)), partialReason: nil,
                        assemblyFailed: false, isPreparingPreview: false, canAccept: true, canDiscard: true,
                        onAccept: {}, onDiscard: {}))
                defer { review.close() }
                let reviewRoot = try context.unwrap("review hosted", review.contentView)
                await E2ESnapshot.settle(reviewRoot)
                let label = try E2EAccessibilityControl.name(for: "scroll.review.preview", in: reviewRoot, context)
                let expectedLabel =
                    switch (portuguese, count) {
                    case (false, 1): "Stitched preview with 1 join"
                    case (false, _): "Stitched preview with 2 joins"
                    case (true, 1): "Pré-visualização unida com 1 junção"
                    case (true, _): "Pré-visualização unida com 2 junções"
                    }
                context.check("the preview label reads \(count) join(s) correctly", label == expectedLabel, label)
            }
        }
    }

    private struct HUDFollower: View {
        let model: ScrollSessionModel

        var body: some View {
            ScrollHUDView(
                hud: ScrollHUDState(
                    source: source, state: model.state, mode: model.mode, direction: model.direction,
                    notice: model.notice, acceptedFrames: model.acceptedFrames,
                    outputLength: model.direction == .horizontal ? model.outputSize.width : model.outputSize.height),
                onChooseDirection: { model.chooseDirection($0) }, onStart: { model.start() },
                onPause: { model.pause() }, onResume: { model.resume() },
                onStop: { model.stop() }, onCancel: { model.cancel() })
        }

        private var source: String {
            guard case .region(let rect, let display)? = model.target else { return "" }
            return String(
                localized: "Area of \(Int(rect.width)) × \(Int(rect.height)) points on \(display.localizedName)")
        }
    }

    /// Mirrors the app's private review adapter.
    private struct ReviewFollower: View {
        let model: ScrollSessionModel

        var body: some View {
            ScrollReviewView(
                preview: model.preview, outputSize: model.outputSize, direction: model.direction, seams: model.seams,
                partialReason: model.partialReason, assemblyFailed: model.notice == .assemblyFailed,
                isPreparingPreview: model.isPreparingPreview, canAccept: model.canAccept,
                canDiscard: model.canDiscard, onAccept: {}, onDiscard: {})
        }
    }
#endif
