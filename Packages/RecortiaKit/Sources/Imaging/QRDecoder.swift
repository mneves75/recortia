import CoreGraphics
import Foundation
import Vision

enum QRDecodingError: Error, Equatable, Sendable {
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
        let codes = observations.filter { $0.symbology == .qr }
        return
            Self.readingOrder(codes.map { $0.boundingBox.cgRect })
            .map { codes[$0] }
            .compactMap { observation in
                guard let raw = observation.payloadData,
                    let bytes = QRBitstream.messageBytes(
                        fromDataCodewords: raw, expectedString: observation.payloadString)
                else { return nil }
                return QRPayloadClassifier.classify(bytes)
            }
    }

    /// Vision boxes are normalized with a bottom-left origin, so a larger maxY is higher up.
    /// Rows are assigned first, top down: a box joins the row started by the highest box above
    /// it when their tops are within half the smaller height. Each row then reads left to right.
    /// Every key ends in a total order, so the result never depends on Vision's input order.
    static func readingOrder(_ boxes: [CGRect]) -> [Int] {
        func key(_ i: Int) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            (-boxes[i].maxY, boxes[i].minX, boxes[i].height, boxes[i].width)
        }
        let topDown = boxes.indices.sorted { key($0) < key($1) }
        var rows: [[Int]] = []
        for index in topDown {
            if let anchor = rows.last?.first,
                boxes[anchor].maxY - boxes[index].maxY < min(boxes[anchor].height, boxes[index].height) / 2
            {
                rows[rows.count - 1].append(index)
            } else {
                rows.append([index])
            }
        }
        func rowKey(_ i: Int) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            (boxes[i].minX, -boxes[i].maxY, boxes[i].height, boxes[i].width)
        }
        return rows.flatMap { row in row.sorted { rowKey($0) < rowKey($1) } }
    }
}
