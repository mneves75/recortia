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
            let hud = HostingPanel(title: "", activating: false)
            hud.setContent(HUDFollower(model: model))
            E2ESnapshot.park(hud)
            defer { hud.close() }
            let hudRoot = try context.unwrap("HUD has content", hud.contentView)
            await E2ESnapshot.settle(hudRoot)
            context.snapshot(hudRoot, shot: "hud")

            harness.scrollFrames.release()
            let drained = await E2EWait.until(timeout: .seconds(30)) {
                harness.scrollFrames.isExhausted && harness.scrollFrames.isHolding
            }
            try context.require(
                "every frame was offered", drained, "\(harness.scrollFrames.deliveredCount)/\(frames.count)")
            model.stop()
            context.check("Stop opens the review", model.state == .reviewing, "\(model.state)")
            context.check("the stream was stopped", harness.scrollFrames.stopCount == 1)
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

            let before = harness.editors.controllers.count
            await model.accept()
            let controller = try await E2EActions.waitForNewEditor(harness, after: before, context)
            let asset = try context.unwrap("stitched asset", controller.model.document.assets.values.first)
            context.check("the asset is a complete scroll capture", asset.origin == .scrollCapture(partialReason: nil))
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

    /// Mirrors the app's private HUD adapter over `ScrollSessionModel`.
    private struct HUDFollower: View {
        let model: ScrollSessionModel

        var body: some View {
            ScrollHUDView(
                hud: ScrollHUDState(
                    source: source, state: model.state, mode: model.mode, notice: model.notice,
                    acceptedFrames: model.acceptedFrames, outputHeight: model.outputSize.height),
                onStart: { model.start() }, onPause: { model.pause() }, onResume: { model.resume() },
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
                preview: model.preview, outputSize: model.outputSize, seams: model.seams,
                partialReason: model.partialReason, assemblyFailed: model.notice == .assemblyFailed,
                onAccept: {}, onDiscard: {})
        }
    }
#endif
