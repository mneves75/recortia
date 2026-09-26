import CoreGraphics
import Foundation
import RecortiaFixtures
import Testing

@Suite("Fixtures behave as documented")
struct SecretPairFixtureTests {
    @Test("Secret pairs are identical outside the secret, different inside, and reproducible by seed")
    func secretPairContract() throws {
        let secret = FixtureRect(x: 7, y: 5, width: 20, height: 9)
        for translucent in [false, true] {
            let pair = try SecretPairFixture.make(
                width: 40, height: 30, secret: secret, seed: 11, translucentBackground: translucent)
            let a = try ContainerInspector.pixels(of: pair.a), b = try ContainerInspector.pixels(of: pair.b)
            var insideDiffers = 0
            for y in 0..<30 {
                for x in 0..<40 {
                    if secret.contains(x: x, y: y) {
                        if a.pixel(x: x, y: y) != b.pixel(x: x, y: y) { insideDiffers += 1 }
                    } else {
                        #expect(a.pixel(x: x, y: y) == b.pixel(x: x, y: y))
                    }
                }
            }
            #expect(insideDiffers > secret.width * secret.height / 2)
            let again = try SecretPairFixture.make(
                width: 40, height: 30, secret: secret, seed: 11, translucentBackground: translucent)
            #expect(try ContainerInspector.pixels(of: again.a) == a)
        }
        #expect(throws: FixtureError.invalidArgument) {
            try SecretPairFixture.make(
                width: 10, height: 10, secret: FixtureRect(x: 5, y: 5, width: 6, height: 1), seed: 1)
        }
    }

    @Test("Hand-crafted PNG chunks carry valid CRCs and the inspector lists them")
    func handcraftedPNG() throws {
        let png = try ContainerCrafting.blankOneBitPNG(width: 9, height: 3)
        #expect(try ContainerInspector.pngChunkTypes(png) == ["IHDR", "IDAT", "IEND"])
        let bad = ContainerCrafting.handcraftedPNG(
            width: 1, height: 1, bitDepth: 8, colorType: 6, idat: [1, 2], corruptIDATCRC: true)
        #expect(throws: ContainerInspectionError.badCRC(chunk: "IDAT")) { try ContainerInspector.pngChunkTypes(bad) }
    }
}
