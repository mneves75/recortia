import CoreGraphics
import Domain
import Foundation
import Imaging
import MacPlatform
import Testing

@testable import Features

// Failure modes (B-9b): a preference blob or seal written before the direction existed must still
// load, vertical; a direction changed after Start would stitch frames of one session along two
// axes; a horizontal session that scrolls vertically, asks about the vertical end, marks seams by
// height or measures its pixel scale along the stitched axis would capture the wrong content.
@Suite("Scrolling capture direction (FR-10, B-9b)")
@MainActor
struct ScrollDirectionTests {
    @Test("Vertical by default, also for blobs and seals written before the direction existed")
    func preferenceDefault() throws {
        #expect(Preferences().scrollCaptureDirection == .vertical)
        var stored = Preferences()
        stored.automaticScrollingEnabled = true
        stored.scrollCaptureDirection = .horizontal
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        #expect(object["scrollCaptureDirectionChoice"] as? String == "horizontal")
        object["scrollCaptureDirectionChoice"] = nil
        let data = try JSONSerialization.data(withJSONObject: object)
        let storage = MemoryPreferenceStorage()
        let integrity = FixedKeyPreferenceIntegrity()
        storage.values[SettingsStore.storageKey] = data
        storage.values[SettingsStore.sealKey] = integrity.seal(data)
        let loaded = SettingsStore(storage: storage, integrity: integrity)
        #expect(loaded.loadIssue == nil)
        #expect(loaded.preferences.automaticScrollingEnabled, "the old seal still verifies")
        #expect(loaded.preferences.scrollCaptureDirection == .vertical)
    }

    @Test("The direction is read when the area is chosen, changes only before Start, and is remembered")
    func chosenBeforeStart() async {
        let h = ScrollHarness()
        _ = await h.model.begin()
        h.model.chooseDirection(.horizontal)
        #expect(h.model.direction == .vertical, "no direction is chosen before the area")
        h.model.chooseTarget(h.target)
        #expect(h.model.direction == .vertical)
        h.model.chooseDirection(.horizontal)
        #expect(h.model.direction == .horizontal)
        #expect(h.settings.preferences.scrollCaptureDirection == .horizontal)
        h.model.start()
        await waitFor("collecting") { h.model.state == .collecting && h.frames.frames.waiterCount == 1 }
        #expect(h.stitcher.direction == .horizontal)
        h.model.chooseDirection(.vertical)
        #expect(h.model.direction == .horizontal, "a running session keeps its axis")
        #expect(h.settings.preferences.scrollCaptureDirection == .horizontal)
        h.model.cancel()

        let next = ScrollHarness()
        next.settings.update { $0.scrollCaptureDirection = .horizontal }
        _ = await next.model.begin()
        next.model.chooseTarget(next.target)
        #expect(next.model.direction == .horizontal, "the next session starts with the remembered direction")
        next.model.cancel()
    }

    @Test("A horizontal automatic session scrolls sideways, asks about the horizontal end, and marks columns")
    func horizontalAutomaticSession() async {
        let h = ScrollHarness(trusted: true, automaticPreference: true)
        h.settings.update { $0.scrollCaptureDirection = .horizontal }
        h.scroller.atEnd = true
        // Two moves, then the stationary frames that end an automatic capture.
        h.stitcher.script = [.accepted(offset: 0), .accepted(offset: 40), .stationary, .stationary, .stationary]
        await h.startCollecting()
        for index in 0..<5 {
            h.frames.deliver(width: 8, height: 6)
            await waitFor("frame \(index)") {
                h.model.state == .reviewing || (h.frames.frames.waiterCount == 1 && h.stitcher.appendCount == index + 1)
            }
        }
        await waitFor("reviewing") { h.model.state == .reviewing }
        #expect(!h.scroller.stepDirections.isEmpty)
        #expect(h.scroller.stepDirections.allSatisfy { $0 == .horizontal }, "\(h.scroller.stepDirections)")
        #expect(h.scroller.endQueryDirections == [.horizontal])
        #expect(h.model.partialReason == nil)
        #expect(h.model.outputSize == PixelSize(width: 48, height: 6))
        #expect(h.model.seams == [8], "a seam is the column where the second frame joins")
    }

    @Test("A horizontal stitch's pixel scale is measured across it, from its height")
    func pixelScaleAcrossTheStitch() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: 4_000, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let wide = try #require(context.makeImage())
        let target = CaptureTarget.region(
            Rect(x: 0, y: 0, width: 400, height: 300), display: TestFixtures.primaryDisplay)
        #expect(ScrollSessionModel.pointPixelScale(of: wide, on: target, direction: .horizontal) == 2)
        #expect(ScrollSessionModel.pointPixelScale(of: wide, on: target, direction: .vertical) == 10)
    }
}
