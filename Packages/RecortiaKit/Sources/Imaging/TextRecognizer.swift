import CoreGraphics
import Domain
import Foundation
import Vision

/// Vision's normalized image space: the unit square with a bottom-left origin.
public enum VisionNormalizedSpace {}

extension AffineMap where From == VisionNormalizedSpace, To == SourcePixelSpace {
    /// Normalized bottom-left coordinates to top-left pixels of a `width` x `height` image.
    public static func visionToPixels(width: Int, height: Int) -> AffineMap {
        AffineMap(a: Double(width), b: 0, c: 0, d: -Double(height), tx: 0, ty: Double(height))
    }
}

public enum TextRecognitionError: Error, Equatable, Sendable {
    case noLanguages
    /// Requested languages this OS's recognizer does not support; nothing was recognized.
    case unsupportedLanguages([Locale.Language])
    case recognitionFailed
}

public struct LanguageAvailability: Sendable, Equatable {
    public let available: [Locale.Language]
    public let unavailable: [Locale.Language]
}

/// On-device text recognition with Vision (FR-08). Accurate level, no language correction, no
/// automatic language detection: the text is reported as seen, never repaired.
public struct TextRecognizer: Sendable {
    public init() {}

    @concurrent
    public func supportedLanguages() async -> [Locale.Language] {
        Self.makeRequest().supportedRecognitionLanguages
    }

    @concurrent
    public func availability(of languages: [Locale.Language]) async -> LanguageAvailability {
        let supported = Self.makeRequest().supportedRecognitionLanguages
        let resolved = languages.map { Self.match($0, in: supported) }
        return LanguageAvailability(
            available: resolved.compactMap { $0 },
            unavailable: zip(languages, resolved).filter { $0.1 == nil }.map(\.0))
    }

    /// Recognizes text lines in `image`, in Vision's reading order, with boxes in the image's
    /// top-left pixel space. Throws `CancellationError` when the calling task is canceled.
    @concurrent
    public func recognize(_ image: CGImage, languages: [Locale.Language]) async throws -> OCRResult {
        try Task.checkCancellation()
        guard !languages.isEmpty else { throw TextRecognitionError.noLanguages }
        var request = Self.makeRequest()
        let supported = request.supportedRecognitionLanguages
        let resolved = languages.map { Self.match($0, in: supported) }
        let unavailable = zip(languages, resolved).filter { $0.1 == nil }.map(\.0)
        guard unavailable.isEmpty else { throw TextRecognitionError.unsupportedLanguages(unavailable) }
        request.recognitionLanguages = resolved.compactMap { $0 }

        let observations: [RecognizedTextObservation]
        do {
            observations = try await request.perform(on: image)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Vision can fail transiently while compiling its Neural Engine model; the CPU path
            // needs no compilation, so one retry there turns that into a slower success.
            try Task.checkCancellation()
            Self.useCPU(&request)
            do {
                observations = try await request.perform(on: image)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                throw TextRecognitionError.recognitionFailed
            }
        }
        try Task.checkCancellation()

        let toPixels = AffineMap<VisionNormalizedSpace, SourcePixelSpace>.visionToPixels(
            width: image.width, height: image.height)
        let lines = observations.compactMap { observation -> OCRResult.Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
                .map { toPixels.apply(Point<VisionNormalizedSpace>(x: Double($0.x), y: Double($0.y))) }
            guard let box = Rect.bounding(corners) else { return nil }
            return OCRResult.Line(text: candidate.string, confidence: candidate.confidence, box: box)
        }
        return OCRResult(
            lines: lines, revision: Self.revisionNumber(request.revision),
            languages: request.recognitionLanguages.map(\.maximalIdentifier))
    }

    static func useCPU(_ request: inout RecognizeTextRequest) {
        for (stage, devices) in request.supportedComputeStageDevices {
            guard let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) else { continue }
            request.setComputeDevice(cpu, for: stage)
        }
    }

    static func makeRequest() -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = false
        return request
    }

    /// Supported languages are fully specified (`pt-Latn-BR`); requests may omit the script.
    static func match(_ language: Locale.Language, in supported: [Locale.Language]) -> Locale.Language? {
        supported.first { $0.maximalIdentifier == language.maximalIdentifier }
    }

    static func revisionNumber(_ revision: RecognizeTextRequest.Revision) -> Int {
        switch revision {
        case .revision3: return 3
        @unknown default:
            // A newer SDK revision: its case name carries the number ("revision4").
            return Int(String(describing: revision).filter(\.isNumber)) ?? 0
        }
    }
}
