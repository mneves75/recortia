import AppKit
import Domain
import Foundation
import Testing

@testable import MacPlatform

@MainActor
@Suite("Clipboard sink: one sanitized PNG representation only (FR-07, EXP-02, RED-02)")
struct ClipboardSinkTests {

    @Test("A successful write replaces earlier contents")
    func replacesPriorContents() throws {
        let pasteboard = TestSupport.privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("prior", forType: .string)
        try ClipboardSink(pasteboard: pasteboard).write(TestSupport.snapshot())
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(pasteboard.pasteboardItems?.first?.types == [.png])
    }

    @Test(
        "Snapshots that are not PNG are refused and prior contents stay untouched",
        arguments: [
            TestSupport.snapshot(format: .jpeg(quality: 0.9), bytes: Data([0xFF, 0xD8, 0xFF, 0xE0])),
            TestSupport.snapshot(format: .png, bytes: Data([0xFF, 0xD8, 0xFF, 0xE0])),
            TestSupport.snapshot(format: .png, bytes: Data()),
        ])
    func refusalLeavesPriorContents(snapshot: ShareSnapshot) {
        let pasteboard = TestSupport.privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("prior", forType: .string)
        let changeCount = pasteboard.changeCount
        let typesBefore = pasteboard.types
        #expect(throws: SinkError.clipboardWriteFailed) { try ClipboardSink(pasteboard: pasteboard).write(snapshot) }
        #expect(pasteboard.changeCount == changeCount)
        #expect(pasteboard.string(forType: .string) == "prior")
        #expect(pasteboard.types == typesBefore)
    }
}
