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

/// What a pin can hand to another app (PIN-02).
public enum PinExportAction: Hashable, Sendable {
    case copy
    case drag
}

/// A reference: only a rendered, sanitized image plus the identity it was rendered from.
/// It never references source assets, so it cannot show pixels a later redaction removed.
public struct Pin: Identifiable, Sendable {
    public let id: PinID
    public let image: CGImage
    public let sourceDocumentID: DocumentID?
    public let privacyEpoch: UInt64
    /// Names this pin's exports. Only a pin rendered from a document through the sanitizing
    /// renderer has one; an image added directly cannot be copied or dragged out.
    public let exportID: DocumentID?
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
    @ObservationIgnored private let exports: ExportCoordinator
    /// Renders that were admitted and have not finished. Each holds one pin slot from admission
    /// until its render returns, so overlapping requests cannot allocate more images than fit.
    @ObservationIgnored private var pendingRenders = 0
    /// Advances on Close All Pins; a render admitted before that must not open a pin afterwards.
    @ObservationIgnored private var requestGeneration = 0

    public init(renderer: any RenderService, settings: SettingsStore, export: ExportCoordinator) {
        self.renderer = renderer
        self.settings = settings
        self.exports = export
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
        return try insert(image, source: identity, displayScale: scale ?? 1, exportable: true)
    }

    /// Adds an already rendered, sanitized image.
    @discardableResult
    public func add(_ image: CGImage, source: RequestIdentity?, displayScale: Double) throws(PinError) -> PinID {
        guard canAddPin else { throw .limitReached }
        return try insert(image, source: source, displayScale: displayScale, exportable: false)
    }

    /// Appends a pin into a free slot. A rendering request calls this while still holding its own
    /// reservation, so it checks the committed pins only.
    private func insert(
        _ image: CGImage, source: RequestIdentity?, displayScale: Double, exportable: Bool
    ) throws(PinError) -> PinID {
        guard pins.count < PinLimits.maxPins else { throw .limitReached }
        let (pixels, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        guard !overflow, retainedPixelCount + pixels <= PinLimits.maxTotalPixels else {
            throw .memoryBudgetExceeded
        }
        let pin = Pin(
            id: PinID(), image: image, sourceDocumentID: source?.documentID, privacyEpoch: source?.privacyEpoch ?? 0,
            exportID: exportable ? DocumentID() : nil,
            displayScale: displayScale.isFinite && displayScale > 0 ? displayScale : 1,
            opacity: settings.preferences.pinDefaultOpacity, zoom: 1)
        pins.append(pin)
        return pin.id
    }

    /// Drops every pin of `documentID` rendered before privacy epoch `epoch` (RED-03).
    public func invalidate(documentID: DocumentID, epoch: UInt64) {
        let before = pins.count
        remove { $0.sourceDocumentID == documentID && $0.privacyEpoch < epoch }
        lastInvalidatedCount = before - pins.count
    }

    public func close(_ id: PinID) {
        remove { $0.id == id }
    }

    public func closeAll() {
        requestGeneration += 1
        remove { _ in true }
    }

    /// Copies or drags out the pin's sanitized raster through the export pipeline (PIN-02). A pin
    /// without an export identity, or one removed before the export commits, exports nothing.
    public func export(_ action: PinExportAction, _ id: PinID) async -> ExportOutcome {
        guard let pin = pin(for: id), let exportID = pin.exportID else { return .failed(.staleDocument) }
        return await exports.export(
            action == .copy ? .copy : .drag, pinned: pin.image, exportID: exportID, privacyEpoch: pin.privacyEpoch,
            isCurrent: { [weak self] in self?.pins.contains { $0.exportID == exportID } == true })
    }

    /// Removes pins and revokes any drag offer made from them, before a receiver can ask for it.
    private func remove(where shouldRemove: (Pin) -> Bool) {
        let removed = pins.filter(shouldRemove)
        pins.removeAll(where: shouldRemove)
        for exportID in removed.compactMap(\.exportID) {
            exports.invalidatePendingDrag(documentID: exportID)
        }
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
