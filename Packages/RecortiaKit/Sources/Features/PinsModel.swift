import CoreGraphics
import Domain
import Foundation
import Observation

public typealias PinID = TypedID<PinTag>
public enum PinTag {}

public enum PinError: Error, Hashable, Sendable {
    case limitReached
    /// Adding the pin would exceed `PinLimits.maxTotalPixels`.
    case memoryBudgetExceeded
    case renderFailed
    /// The document changed (revision or privacy epoch) while its pin was rendering.
    case staleDocument
}

/// A floating reference: only a rendered, sanitized image plus the identity it was rendered from.
/// It never references source assets, so it cannot show pixels a later redaction removed.
public struct Pin: Identifiable, Sendable {
    public let id: PinID
    public let image: CGImage
    public let sourceDocumentID: DocumentID?
    public let privacyEpoch: UInt64
    /// Pixels per point used to show the image at its captured size; 1 for imported images.
    public let displayScale: Double
    public var opacity: Double
    public var zoom: Double
}

/// Reference pins (FR-09, PIN-01): at most `PinLimits.maxPins`, invalidated on privacy changes,
/// released on close, never restored after quit.
@MainActor
@Observable
public final class PinsModel {
    public static let opacityRange: ClosedRange<Double> = SettingsStore.opacityRange
    public static let zoomRange: ClosedRange<Double> = 0.25...4

    public private(set) var pins: [Pin] = []
    /// Number of pins removed by the latest privacy invalidation, for a user-visible note.
    public private(set) var lastInvalidatedCount = 0
    /// Increments on Bring Pins Forward; pin windows observe it and order themselves front.
    public private(set) var bringForwardRequest = 0

    @ObservationIgnored private let renderer: any RenderService
    @ObservationIgnored private let settings: SettingsStore
    /// Renders that were admitted and have not finished. Each holds one pin slot from admission
    /// until its render returns, so overlapping requests cannot allocate more images than fit.
    @ObservationIgnored private var pendingRenders = 0
    /// Advances on Close All Pins; a render admitted before that must not open a pin afterwards.
    @ObservationIgnored private var requestGeneration = 0

    public init(renderer: any RenderService, settings: SettingsStore) {
        self.renderer = renderer
        self.settings = settings
    }

    /// True while a new pin has a free slot, counting renders already admitted.
    public var canAddPin: Bool { pins.count + pendingRenders < PinLimits.maxPins }

    /// Rendered pixels currently retained by all pins.
    public var retainedPixelCount: Int { pins.reduce(0) { $0 + $1.image.width * $1.image.height } }

    /// Renders `session` through the sanitizing renderer and pins the result, unless the live
    /// session moved on while rendering.
    @discardableResult
    public func pin(_ session: DocumentSession, currentSession: () -> DocumentSession?) async throws(PinError) -> PinID
    {
        guard canAddPin else { throw .limitReached }
        // The slot stays reserved until the renderer returns, even if the caller is canceled or
        // Close All runs meanwhile: the image is still allocated until then.
        pendingRenders += 1
        defer { pendingRenders -= 1 }
        let generation = requestGeneration
        let identity = session.requestIdentity()
        let image: CGImage
        do {
            image = try await renderer.render(session.document, scale: 1)
        } catch {
            throw .renderFailed
        }
        guard generation == requestGeneration else { throw .staleDocument }
        guard let current = currentSession(), current.accepts(identity) else { throw .staleDocument }
        let scale = session.document.assets.count == 1 ? session.document.assets.values.first?.pointPixelScale : nil
        return try insert(image, source: identity, displayScale: scale ?? 1)
    }

    /// Adds an already rendered, sanitized image.
    @discardableResult
    public func add(_ image: CGImage, source: RequestIdentity?, displayScale: Double) throws(PinError) -> PinID {
        guard canAddPin else { throw .limitReached }
        return try insert(image, source: source, displayScale: displayScale)
    }

    /// Appends a pin into a free slot. A rendering request calls this while still holding its own
    /// reservation, so it checks the committed pins only.
    private func insert(_ image: CGImage, source: RequestIdentity?, displayScale: Double) throws(PinError) -> PinID {
        guard pins.count < PinLimits.maxPins else { throw .limitReached }
        let (pixels, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        guard !overflow, retainedPixelCount + pixels <= PinLimits.maxTotalPixels else {
            throw .memoryBudgetExceeded
        }
        let pin = Pin(
            id: PinID(), image: image, sourceDocumentID: source?.documentID, privacyEpoch: source?.privacyEpoch ?? 0,
            displayScale: displayScale.isFinite && displayScale > 0 ? displayScale : 1,
            opacity: settings.preferences.pinDefaultOpacity, zoom: 1)
        pins.append(pin)
        return pin.id
    }

    /// Drops every pin of `documentID` rendered before privacy epoch `epoch` (RED-03).
    public func invalidate(documentID: DocumentID, epoch: UInt64) {
        let before = pins.count
        pins.removeAll { $0.sourceDocumentID == documentID && $0.privacyEpoch < epoch }
        lastInvalidatedCount = before - pins.count
    }

    public func close(_ id: PinID) {
        pins.removeAll { $0.id == id }
    }

    public func closeAll() {
        requestGeneration += 1
        pins.removeAll()
    }

    public func bringForward() {
        bringForwardRequest += 1
    }

    public func setOpacity(_ opacity: Double, for id: PinID) {
        let value = opacity.isFinite ? opacity : Self.opacityRange.lowerBound
        update(id) { $0.opacity = min(max(value, Self.opacityRange.lowerBound), Self.opacityRange.upperBound) }
    }

    public func setZoom(_ zoom: Double, for id: PinID) {
        let value = zoom.isFinite ? zoom : 1
        update(id) { $0.zoom = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound) }
    }

    public func pin(for id: PinID) -> Pin? {
        pins.first { $0.id == id }
    }

    private func update(_ id: PinID, _ change: (inout Pin) -> Void) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        change(&pins[index])
    }
}
