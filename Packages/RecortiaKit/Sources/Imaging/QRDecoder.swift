import CoreGraphics
import Foundation
import Vision

public enum QRDecodingError: Error, Equatable, Sendable {
    case detectionFailed
}

/// On-device QR detection with Vision. Payloads are returned as untrusted data with their exact
/// bytes; decoding never opens, fetches, or acts on them (FR-08, OCR-02).
public struct QRDecoder: Sendable {
    public init() {}

    /// Payloads in reading order (top to bottom, then left to right). Codes whose exact bytes
    /// cannot be recovered are omitted rather than approximated.
    @concurrent
    public func decode(_ image: CGImage) async throws -> [QRPayload] {
        try Task.checkCancellation()
        var request = DetectBarcodesRequest()
        request.symbologies = [.qr]
        let observations: [BarcodeObservation]
        do {
            observations = try await request.perform(on: image)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw QRDecodingError.detectionFailed
        }
        try Task.checkCancellation()
        return
            observations
            .filter { $0.symbology == .qr }
            .sorted(by: Self.readingOrder)
            .compactMap { observation in
                guard let raw = observation.payloadData,
                    let bytes = QRBitstream.messageBytes(
                        fromDataCodewords: raw, expectedString: observation.payloadString)
                else { return nil }
                return QRPayloadClassifier.classify(bytes)
            }
    }

    /// Vision boxes are normalized with a bottom-left origin, so a larger maxY is higher up.
    private static func readingOrder(_ a: BarcodeObservation, _ b: BarcodeObservation) -> Bool {
        let boxA = a.boundingBox.cgRect, boxB = b.boundingBox.cgRect
        let sameRow = abs(boxA.maxY - boxB.maxY) < min(boxA.height, boxB.height) / 2
        return sameRow ? boxA.minX < boxB.minX : boxA.maxY > boxB.maxY
    }
}
