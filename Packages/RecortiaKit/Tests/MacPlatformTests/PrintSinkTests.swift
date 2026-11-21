import AppKit
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import MacPlatform

@MainActor
@Suite("Print sink: the print panel shows only the snapshot's sanitized PNG (B-9a)")
struct PrintSinkTests {
    private static func pngSnapshot(width: Int, height: Int) throws -> ShareSnapshot {
        let image = try #require(TestSupport.image(width: width, height: height))
        return TestSupport.snapshot(
            bytes: try ContainerCrafting.pngData(image), suggestedFilename: "Recortia 2026-11-21 at 10.00.00.png",
            pixelSize: PixelSize(width: width, height: height))
    }

    @Test("The operation prints one image view of the snapshot's pixels, fit to the page and centred")
    func operationShowsSnapshot() throws {
        let snapshot = try Self.pngSnapshot(width: 300, height: 120)
        let operation = try PrintSink.operation(for: snapshot)
        let view = try #require(operation.view as? NSImageView)
        #expect(view.frame.size == NSSize(width: 300, height: 120))
        let representation = try #require(view.image?.representations.first as? NSBitmapImageRep)
        #expect(representation.pixelsWide == 300 && representation.pixelsHigh == 120)
        #expect(view.image?.representations.count == 1)
        let info = operation.printInfo
        #expect(info.horizontalPagination == .fit && info.verticalPagination == .fit)
        #expect(info.isHorizontallyCentered && info.isVerticallyCentered)
        #expect(info.orientation == .landscape)
        #expect(operation.showsPrintPanel)
        #expect(operation.printPanel.options.contains(.showsPreview))
        #expect(operation.jobTitle == "Recortia 2026-11-21 at 10.00.00")
        let tall = try PrintSink.operation(for: Self.pngSnapshot(width: 80, height: 200))
        #expect(tall.printInfo.orientation == .portrait)
    }

    @Test(
        "Anything but a decodable PNG of the declared size is refused",
        arguments: [
            TestSupport.snapshot(format: .jpeg(quality: 0.9), bytes: Data([0xFF, 0xD8, 0xFF, 0xE0])),
            TestSupport.snapshot(format: .png, bytes: Data([0xFF, 0xD8, 0xFF, 0xE0])),
            TestSupport.snapshot(format: .png),
            TestSupport.snapshot(format: .png, bytes: Data()),
        ])
    func refusesNonPNG(snapshot: ShareSnapshot) {
        #expect(throws: SinkError.printFailed) { try PrintSink.operation(for: snapshot) }
    }

    @Test("A PNG whose size differs from the snapshot's is refused")
    func refusesSizeMismatch() throws {
        let image = try #require(TestSupport.image(width: 8, height: 8))
        let snapshot = TestSupport.snapshot(bytes: try ContainerCrafting.pngData(image))  // declares 4 × 4
        #expect(throws: SinkError.printFailed) { try PrintSink.operation(for: snapshot) }
    }
}
