import Foundation
import Testing

@testable import Domain

@Suite("Geometry contract (GEO-02)")
struct GeometryTests {
    @Test("Non-finite and negative rects are rejected")
    func rejectsInvalidRects() {
        let bad: [Rect<DocumentSpace>] = [
            Rect(x: .nan, y: 0, width: 10, height: 10),
            Rect(x: 0, y: .infinity, width: 10, height: 10),
            Rect(x: 0, y: 0, width: -1, height: 10),
            Rect(x: 0, y: 0, width: 10, height: .nan),
        ]
        for rect in bad {
            #expect(throws: GeometryError.self) { try rect.validated() }
        }
        #expect(throws: Never.self) { try Rect<DocumentSpace>(x: -5, y: -5, width: 0, height: 0).validated() }
    }

    @Test("Standardizing flips negative spans from any drag direction")
    func standardizesAllDragDirections() {
        let expected = Rect<DisplaySpace>(x: 10, y: 20, width: 30, height: 40)
        let corners: [(Point<DisplaySpace>, Point<DisplaySpace>)] = [
            (Point(x: 10, y: 20), Point(x: 40, y: 60)),
            (Point(x: 40, y: 60), Point(x: 10, y: 20)),
            (Point(x: 40, y: 20), Point(x: 10, y: 60)),
            (Point(x: 10, y: 60), Point(x: 40, y: 20)),
        ]
        for (a, b) in corners {
            #expect(Rect(spanning: a, b) == expected)
        }
    }

    @Test("Outward rounding covers every intended pixel and clips to bounds")
    func outwardRoundingCovers() throws {
        let bounds = PixelSize(width: 100, height: 50)
        let covered = try #require(
            try PixelRect.covering(Rect<SourcePixelSpace>(x: 1.2, y: 2.9, width: 3.1, height: 0.2), within: bounds))
        #expect(covered == PixelRect(x: 1, y: 2, width: 4, height: 2))

        let edge = try #require(
            try PixelRect.covering(Rect<SourcePixelSpace>(x: -3.5, y: 48.5, width: 10, height: 10), within: bounds))
        #expect(edge == PixelRect(x: 0, y: 48, width: 7, height: 2))

        #expect(
            try PixelRect.covering(Rect<SourcePixelSpace>(x: 200, y: 0, width: 5, height: 5), within: bounds) == nil)
    }

    @Test("Covering rejects coordinates that would overflow")
    func coveringRejectsOverflow() {
        let huge = Rect<SourcePixelSpace>(x: 1e300, y: 0, width: 1e300, height: 1)
        #expect(throws: GeometryError.self) {
            try PixelRect.covering(huge, within: PixelSize(width: 10, height: 10))
        }
    }

    @Test(
        "Affine round trips agree within tolerance",
        arguments: [
            (2.0, 0.0, 15.0, -7.5), (0.5, Double.pi / 2, 0.0, 0.0), (1.25, 0.3, -100.0, 42.0),
            (3.0, -Double.pi, 7.0, 7.0),
        ])
    func roundTrip(scale: Double, rotation: Double, tx: Double, ty: Double) throws {
        let map = AffineMap<SourcePixelSpace, DocumentSpace>.rotation(rotation)
            .then(.scale(scale))
            .then(.translation(dx: tx, dy: ty))
        let inverse = try map.inverted()
        for p in [Point<SourcePixelSpace>(x: 0, y: 0), Point(x: 123.25, y: -9), Point(x: 1e4, y: 3e3)] {
            let back = inverse.apply(map.apply(p))
            #expect(abs(back.x - p.x) < 1e-6 && abs(back.y - p.y) < 1e-6)
        }
    }

    @Test("Singular transforms cannot be inverted")
    func singularInverse() {
        let collapse = AffineMap<SourcePixelSpace, DocumentSpace>.scale(0)
        #expect(throws: GeometryError.singularTransform) { try collapse.inverted() }
    }

    @Test("Rect mapping returns the bounding box of all four corners")
    func rectMappingUnderRotation() {
        let map = AffineMap<SourcePixelSpace, DocumentSpace>.rotation(.pi / 2)
        let mapped = map.apply(Rect<SourcePixelSpace>(x: 0, y: 0, width: 10, height: 4))
        #expect(abs(mapped.minX - -4) < 1e-9 && abs(mapped.maxX - 0) < 1e-9)
        #expect(abs(mapped.minY - 0) < 1e-9 && abs(mapped.maxY - 10) < 1e-9)
    }

    @Test("Pixel area arithmetic reports overflow instead of trapping")
    func pixelAreaOverflow() {
        #expect(PixelSize(width: 8000, height: 5000).checkedArea == 40_000_000)
        #expect(PixelSize(width: .max, height: 2).checkedArea == nil)
        #expect(PixelSize(width: -1, height: 2).checkedArea == nil)
    }

    @Test("Imported images carry no screen-point scale")
    func importedAssetHasNoPointScale() {
        let info = ImageAssetInfo(id: AssetID(), pixelSize: PixelSize(width: 20, height: 10), origin: .imported)
        #expect(info.pointPixelScale == nil)
        let geometry = CaptureGeometry(
            source: .display(id: 1), desktopBounds: Rect(x: -1440, y: 0, width: 10, height: 5),
            pointPixelScale: 2, pixelSize: PixelSize(width: 20, height: 10), capturedAt: Date(timeIntervalSince1970: 0))
        let captured = ImageAssetInfo(id: AssetID(), pixelSize: geometry.pixelSize, origin: .captured(geometry))
        #expect(captured.pointPixelScale == 2)
    }
}
