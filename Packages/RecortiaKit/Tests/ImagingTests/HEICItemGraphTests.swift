import CoreGraphics
import Domain
import Foundation
import ImageIO
import RecortiaFixtures
import Testing

@testable import Imaging

/// B-9a (RED-02), from the T5/T6 acceptance review: a HEIC export holds one picture, the primary item, and
/// nothing derived from it beside the tiles that compose it. Box and item types alone cannot say
/// that: a thumbnail, or a second picture, is another `hvc1` item, told apart only by `iref`.
@Suite(
    "A HEIC export holds the primary picture and its tiles only",
    .enabled(if: ExportCapabilities.encodesHEIC, "this Mac's ImageIO does not encode HEIC"))
struct HEICItemGraphTests {
    /// The item graph of a HEIC file: every item ID with its type, the primary item, and each
    /// `iref` reference as (type, from, to).
    struct ItemGraph {
        var items: [Int: String] = [:]
        var primary: Int?
        var references: [(type: String, from: Int, to: [Int])] = []

        var referenceTypes: Set<String> { Set(references.map(\.type)) }

        /// Items nothing reaches from the primary item through `dimg`: a picture of its own.
        var unreachableItems: Set<Int> {
            guard let primary else { return Set(items.keys) }
            var reached: Set<Int> = [primary]
            for reference in references where reference.type == "dimg" && reference.from == primary {
                reached.formUnion(reference.to)
            }
            return Set(items.keys).subtracting(reached)
        }
    }

    /// Reads `pitm`, `iinf`/`infe` and `iref` straight from the ISOBMFF bytes.
    static func itemGraph(_ data: Data) throws -> ItemGraph {
        let bytes = [UInt8](data)
        func uint(_ offset: Int, _ size: Int) -> Int { (0..<size).reduce(0) { $0 << 8 | Int(bytes[offset + $1]) } }
        func type(_ offset: Int) -> String { String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self) }
        func boxes(_ start: Int, _ end: Int) throws -> [(type: String, body: Range<Int>)] {
            var result: [(type: String, body: Range<Int>)] = []
            var offset = start
            while offset + 8 <= end {
                var size = uint(offset, 4)
                var header = 8
                if size == 1 {
                    size = uint(offset + 8, 8)
                    header = 16
                } else if size == 0 {
                    size = end - offset
                }
                try #require(size >= header && offset + size <= end, "truncated box at \(offset)")
                result.append((type(offset + 4), (offset + header)..<(offset + size)))
                offset += size
            }
            return result
        }
        var graph = ItemGraph()
        let meta = try #require(try boxes(0, bytes.count).first { $0.type == "meta" })
        for child in try boxes(meta.body.lowerBound + 4, meta.body.upperBound) {
            let body = child.body
            let version = Int(bytes[body.lowerBound])
            switch child.type {
            case "pitm":
                graph.primary = uint(body.lowerBound + 4, version == 0 ? 2 : 4)
            case "iinf":
                let start = body.lowerBound + 4 + (version == 0 ? 2 : 4)
                for entry in try boxes(start, body.upperBound) where entry.type == "infe" {
                    let entryVersion = Int(bytes[entry.body.lowerBound])
                    try #require(entryVersion >= 2, "infe version \(entryVersion)")
                    let idSize = entryVersion == 2 ? 2 : 4
                    let id = uint(entry.body.lowerBound + 4, idSize)
                    graph.items[id] = type(entry.body.lowerBound + 4 + idSize + 2)
                }
            case "iref":
                let idSize = version == 0 ? 2 : 4
                for reference in try boxes(body.lowerBound + 4, body.upperBound) {
                    var offset = reference.body.lowerBound
                    let from = uint(offset, idSize)
                    offset += idSize
                    let count = uint(offset, 2)
                    offset += 2
                    let to = (0..<count).map { uint(offset + $0 * idSize, idSize) }
                    graph.references.append((reference.type, from, to))
                }
            default: break
            }
        }
        return graph
    }

    static func exported(width: Int, height: Int) async throws -> ShareSnapshot {
        let harness = ImagingHarness()
        let asset = try await harness.add(try ChartFixture.photographic(width: width, height: height))
        var session = DocumentSession(document: Document(asset: asset))
        try session.addSecureMask(covering: Rect(x: 40, y: 40, width: 120, height: 80))
        return try await harness.export(session, ExportOptions(format: .heic(quality: 0.85)))
    }

    @Test(
        "The pipeline's HEIC, small or tiled, is the primary item and its grid tiles, with no reference but dimg",
        // Odd and tile-edge sizes, and the tall and wide shapes of vertical and horizontal scrolling
        // captures: the allowlist fails closed, so any shape ImageIO writes that it refuses is a
        // HEIC save that fails for the person.
        arguments: [(320, 240), (161, 121), (513, 1025), (1999, 1001), (5120, 2880), (1200, 16000), (16000, 900)])
    func pipelineItemGraph(width: Int, height: Int) async throws {
        let snapshot = try await Self.exported(width: width, height: height)
        let graph = try Self.itemGraph(snapshot.bytes)
        let primary = try #require(graph.primary)
        #expect(graph.items[primary] != nil, "the primary item is declared")
        #expect(graph.referenceTypes.isSubset(of: ["dimg"]), "references: \(graph.referenceTypes)")
        #expect(graph.unreachableItems.isEmpty, "items outside the primary picture: \(graph.unreachableItems)")
        if width * height > 4_000_000 {
            // Control: a large export really is tiled, so the dimg path was exercised.
            #expect(graph.items[primary] == "grid" && graph.items.count > 1, "items: \(graph.items)")
        }
        let decodedPixels = try decoded(snapshot)
        #expect(decodedPixels.width == width && decodedPixels.height == height)
    }

    // RED-02 defence in depth: a thumbnail is a second hvc1 item tied by `iref thmb`, and a
    // second picture is an hvc1 item nothing reaches from the primary one; both are refused.
    @Test("The HEIC allowlist refuses a thumbnail item and a second picture")
    func allowlistRefusesExtraPictures() throws {
        let image = try ChartFixture.geometryChart(width: 320, height: 240)
        let thumbnailed = try ContainerCrafting.encode(
            [image], type: "public.heic",
            properties: [kCGImageDestinationEmbedThumbnail: true, kCGImageDestinationLossyCompressionQuality: 0.9])
        // Control: the fixture really carries a thumbnail item.
        try #require(try Self.itemGraph(thumbnailed).referenceTypes.contains("thmb"))
        #expect(throws: ExportError.encodingFailed) { try ExportContainerFilter.heic(thumbnailed) }

        let other = try ChartFixture.photographic(width: 320, height: 240)
        let twoPictures = try ContainerCrafting.encode([image, other], type: "public.heic")
        try #require(try Self.itemGraph(twoPictures).unreachableItems.count == 1)
        #expect(throws: ExportError.encodingFailed) { try ExportContainerFilter.heic(twoPictures) }
    }
}
