import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

// Failure mode (FR-06, RED-01, audit hardening): a layer added or moved under an existing mask
// after the mask was drawn is covered only by the mask's output rectangle, not by source-bound
// regions. If cosmetic blur/pixelate runs before output masks, the effect averages the hidden
// pixels into the band just outside the black box.
@Suite("Masks cover late layers before cosmetic effects sample them")
struct RenderLateLayerRedactionTests {
    private func export(_ secretImage: CGImage, masked: Bool, harness: ImagingHarness) async throws -> DecodedPixels {
        let base = try await harness.add(
            try ChartFixture.solid(
                width: RedactionFixtures.width, height: RedactionFixtures.height,
                color: ChartFixture.Color(200, 200, 200)))
        let secret = RedactionFixtures.secret
        var session = DocumentSession(document: Document(asset: base))
        if masked {
            try session.addSecureMask(covering: secret.documentRect, fill: RGBA(r: 12, g: 34, b: 56))
        }
        let late = try await harness.add(secretImage)
        try session.perform("Add late layer") { document in
            document.assets[late.id] = late
            document.layers.append(ImageLayer(assetID: late.id))
            document.obfuscations = [
                CosmeticObfuscation(
                    rect: Rect(
                        x: Double(secret.x - 8), y: Double(secret.y - 8), width: Double(secret.width + 16),
                        height: Double(secret.height + 16)),
                    style: .blur(radius: 6)),
                CosmeticObfuscation(
                    rect: Rect(x: Double(secret.maxX), y: Double(secret.y), width: 12, height: Double(secret.height)),
                    style: .pixelate(blockSize: 5)),
            ]
        }
        if masked { #expect(session.document.masks[0].sourceRegions[late.id] == nil, "precondition: late layer") }
        return try decoded(try await harness.export(session))
    }

    // Failure mode (security run-2): a late layer that is scaled is resampled when drawn; if only
    // the output-space fill covers it, pixels just outside the mask edge average hidden pixels.
    private func exportScaled(_ secretImage: CGImage, masked: Bool, harness: ImagingHarness) async throws
        -> DecodedPixels
    {
        let base = try await harness.add(
            try ChartFixture.solid(
                width: RedactionFixtures.width, height: RedactionFixtures.height,
                color: ChartFixture.Color(200, 200, 200)))
        let secret = RedactionFixtures.secret
        let placement = LayerPlacement(translation: Point(x: 3.37, y: 2.61), scale: 0.8)
        let covered = Rect<DocumentSpace>(
            x: placement.translation.x + Double(secret.x) * placement.scale,
            y: placement.translation.y + Double(secret.y) * placement.scale,
            width: Double(secret.width) * placement.scale, height: Double(secret.height) * placement.scale)
        var session = DocumentSession(document: Document(asset: base))
        if masked { try session.addSecureMask(covering: covered, fill: RGBA(r: 12, g: 34, b: 56)) }
        let late = try await harness.add(secretImage)
        try session.perform("Add scaled late layer") { document in
            document.assets[late.id] = late
            document.layers.append(ImageLayer(assetID: late.id, placement: placement))
        }
        return try decoded(try await harness.export(session))
    }

    @Test("A scaled late layer under a mask is masked before it is resampled", arguments: [1, 7, 42] as [UInt64])
    func scaledLateLayerIsIndependentOfHiddenPixels(seed: UInt64) async throws {
        let harness = ImagingHarness()
        let pair = try RedactionFixtures.pair(seed: seed)
        let maskedA = try await exportScaled(pair.a, masked: true, harness: harness)
        let maskedB = try await exportScaled(pair.b, masked: true, harness: harness)
        #expect(maskedA == maskedB, "masked exports must be byte-identical")
        let plainA = try await exportScaled(pair.a, masked: false, harness: harness)
        let plainB = try await exportScaled(pair.b, masked: false, harness: harness)
        #expect(plainA != plainB, "control: without the mask the secret must be visible")
    }

    @Test(
        "Exports do not depend on pixels hidden under a mask in a layer added later", arguments: [1, 7, 42] as [UInt64])
    func lateLayerIsIndependentOfHiddenPixels(seed: UInt64) async throws {
        let harness = ImagingHarness()
        let pair = try RedactionFixtures.pair(seed: seed)
        let maskedA = try await export(pair.a, masked: true, harness: harness)
        let maskedB = try await export(pair.b, masked: true, harness: harness)
        #expect(maskedA == maskedB, "masked exports must be byte-identical")
        let plainA = try await export(pair.a, masked: false, harness: harness)
        let plainB = try await export(pair.b, masked: false, harness: harness)
        #expect(plainA != plainB, "control: without the mask the secret must be visible")
    }
}
