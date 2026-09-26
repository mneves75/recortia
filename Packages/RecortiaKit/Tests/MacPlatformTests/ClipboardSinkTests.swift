import AppKit
import Domain
import Foundation
import ImageIO
import Testing

@testable import MacPlatform

/// Types AppKit advertises on read for a single stored `public.png` item: its legacy PNG alias and
/// on-demand TIFF conversions of that same PNG. They are not stored representations.
private let systemTranslationsOfPNG: Set<NSPasteboard.PasteboardType> = [
    .png, NSPasteboard.PasteboardType("Apple PNG pasteboard type"), .tiff,
    NSPasteboard.PasteboardType("NeXT TIFF v4.0 pasteboard type"),
]

private func encodedPNG(width: Int, height: Int) throws -> Data {
    let image = try #require(TestSupport.image(width: width, height: height))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@MainActor
@Suite("Clipboard sink: one sanitized PNG representation only (FR-07, EXP-02, RED-02)")
struct ClipboardSinkTests {
    @Test("A PNG snapshot is published as exactly one public.png item with identical bytes")
    func writesOnlyPNG() throws {
        let pasteboard = TestSupport.privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let snapshot = TestSupport.snapshot()
        try ClipboardSink(pasteboard: pasteboard).write(snapshot)
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(pasteboard.pasteboardItems?.first?.types == [.png])
        #expect(pasteboard.data(forType: .png) == snapshot.bytes)
        let advertised = Set(pasteboard.types ?? [])
        #expect(advertised.contains(.png))
        #expect(advertised.isSubset(of: systemTranslationsOfPNG))
        #expect(pasteboard.string(forType: .fileURL) == nil)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test("Any TIFF AppKit offers is converted from the one sanitized PNG, not a second representation")
    func tiffIsTranslationOfPNG() throws {
        let pasteboard = TestSupport.privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let png = try encodedPNG(width: 7, height: 3)
        try ClipboardSink(pasteboard: pasteboard).write(TestSupport.snapshot(bytes: png))
        #expect(pasteboard.pasteboardItems?.first?.types == [.png])
        #expect(pasteboard.data(forType: .png) == png)
        if pasteboard.types?.contains(.tiff) == true {
            let tiff = try #require(pasteboard.data(forType: .tiff))
            let source = try #require(CGImageSourceCreateWithData(tiff as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 7)
            #expect(image.height == 3)
        }
    }

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
