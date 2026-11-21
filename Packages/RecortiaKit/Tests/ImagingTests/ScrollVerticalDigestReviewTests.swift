import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

/// Independent review of B-9b: a vertical capture's assembled image and its review preview, which
/// the horizontal change rewrote, stay byte-identical to the stitcher before it learned a
/// direction. The digests were produced by running this scenario against a `git archive` of
/// c638bb8 (with `preview(maxHeight:)`) and match this tree exactly.
@Suite("Review: vertical stitch and preview are byte-identical to c638bb8")
struct ScrollVerticalDigestReviewTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let seed: UInt64
        let kind: ScrollPageFixture.Kind
        let pageHeight: Int
        let noisy: Bool
        let size: String
        let assemble: UInt64
        let preview2000: String
        let preview500: String
        var testDescription: String { "seed \(seed)" }
    }

    static let cases: [Case] = [
        Case(
            seed: 3, kind: .text, pageHeight: 3000, noisy: true, size: "240x3064", assemble: 0x45f6_2ba3_0cb7_93de,
            preview2000: "157x2000:4e895e3c5a4c72c2", preview500: "39x500:a66e62473e3fcb44"),
        Case(
            seed: 41, kind: .text, pageHeight: 2600, noisy: true, size: "240x2664", assemble: 0xe884_dffd_7a29_9060,
            preview2000: "180x2000:daa46d5b782c104", preview500: "45x500:92402be04040521e"),
        Case(
            seed: 19, kind: .text, pageHeight: 3200, noisy: false, size: "240x3264", assemble: 0xacce_5625_7244_8ec5,
            preview2000: "147x2000:776279e685749af7", preview500: "37x500:4ad91cd04224570b"),
    ]

    static func digest(_ buffer: ScrollPageBuffer) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in buffer.pixels { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return hash
    }

    static func describe(_ buffer: ScrollPageBuffer) -> String {
        "\(buffer.width)x\(buffer.height):\(String(digest(buffer), radix: 16))"
    }

    @Test("Assembled image and both preview scales match the pre-change stitcher", arguments: cases)
    func matchesPreChangeStitcher(_ expected: Case) throws {
        let fixture = ScrollPageFixture(
            seed: expected.seed, kind: expected.kind, pageHeight: expected.pageHeight, animated: expected.noisy,
            noisy: expected.noisy)
        var stitcher = ScrollStitcher()
        let offsets = fixture.forwardOffsets(steps: 40...150)
        _ = ScrollHarness.run(fixture, frames: ScrollHarness.script(fixture, offsets: offsets), stitcher: &stitcher)
        let output = try #require(ScrollHarness.rgba(try stitcher.assemble()))
        #expect("\(output.width)x\(output.height)" == expected.size)
        #expect(Self.digest(output) == expected.assemble, "assemble \(String(Self.digest(output), radix: 16))")
        let preview2000 = try #require(stitcher.preview(maxLength: 2000).flatMap(ScrollHarness.rgba))
        #expect(Self.describe(preview2000) == expected.preview2000)
        let preview500 = try #require(stitcher.preview(maxLength: 500).flatMap(ScrollHarness.rgba))
        #expect(Self.describe(preview500) == expected.preview500)
    }
}
