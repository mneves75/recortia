import Domain
import Testing

@testable import Features

// Failure mode (FR-10, SCR-02): an accepted partial scrolling capture opens in the editor looking
// complete. "A user-confirmed partial result may be exported, but must never be labeled complete."
@Suite("Partial scrolling captures stay labeled in the editor (FR-10)")
@MainActor
struct EditorPartialCaptureTests {
    private func session(origin: AssetOrigin) -> DocumentSession {
        let asset = ImageAssetInfo(id: AssetID(), pixelSize: PixelSize(width: 40, height: 400), origin: origin)
        return DocumentSession(document: Document(asset: asset))
    }

    @Test("A partial scroll capture exposes its reason; a complete one and other origins do not")
    func partialReasonIsExposed() {
        let partial = EditorHarness(session: session(origin: .scrollCapture(partialReason: .limit(.height))))
        #expect(partial.model.partialScrollCaptureReason == .limit(.height))

        let complete = EditorHarness(session: session(origin: .scrollCapture(partialReason: nil)))
        #expect(complete.model.partialScrollCaptureReason == nil)

        let imported = EditorHarness(session: session(origin: .imported))
        #expect(imported.model.partialScrollCaptureReason == nil)
    }
}
