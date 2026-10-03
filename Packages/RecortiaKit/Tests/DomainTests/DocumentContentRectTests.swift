import Foundation
import Testing

@testable import Domain

@Suite("FR-07: exported content region")
struct DocumentContentRectTests {
    private func document(crop: Rect<DocumentSpace>?) -> Document {
        Document(assets: [:], canvasSize: Size(width: 100, height: 100), layers: [], crop: crop)
    }

    @Test("No crop exports the whole canvas; a partial crop clips to it")
    func absentAndPartial() {
        #expect(document(crop: nil).contentRect == Rect(x: 0, y: 0, width: 100, height: 100))
        #expect(
            document(crop: Rect(x: 80, y: 90, width: 50, height: 50)).contentRect
                == Rect(x: 80, y: 90, width: 20, height: 10))
    }

    @Test("An explicit crop with nothing on the canvas has an empty content region, not the whole canvas")
    func unusableCropIsEmpty() {
        #expect(document(crop: Rect(x: 150, y: 0, width: 20, height: 20)).contentRect.isEmpty)
        #expect(document(crop: Rect(x: 10, y: 10, width: 0, height: 20)).contentRect.isEmpty)
        #expect(document(crop: Rect(x: 10, y: 10, width: 20, height: 0)).contentRect.isEmpty)
    }
}
