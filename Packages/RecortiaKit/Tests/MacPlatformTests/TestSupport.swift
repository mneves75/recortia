import AppKit
import CoreGraphics
import Domain
import Foundation
import MacPlatform

/// Shared helpers for MacPlatform tests. Nothing here touches the real screen, the general
/// pasteboard, permissions, or input events.
enum TestSupport {
    /// The PNG signature; `snapshot` appends arbitrary bytes to it. Sinks treat snapshots as opaque
    /// sanitized bytes, so these fixtures need no complete PNG container.
    static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    static func snapshot(
        format: ExportFormat = .png, bytes: Data? = nil,
        suggestedFilename: String = "Recortia 2026-09-26 at 10.00.00.png", filename: ExportName? = nil
    ) -> ShareSnapshot {
        let payload = bytes ?? (pngSignature + Data((0..<256).map { UInt8($0 & 0xFF) }))
        return ShareSnapshot(
            documentID: DocumentID(), revision: 3, privacyEpoch: 1, format: format,
            pixelSize: PixelSize(width: 4, height: 4), bytes: payload,
            filename: filename ?? ExportName(literal: suggestedFilename))
    }

    static func image(width: Int, height: Int) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func display(
        id: CGDirectDisplayID, x: Double, y: Double, width: Double, height: Double, scale: Double,
        rotation: Double = 0
    ) -> DisplayInfo {
        let frame = Rect<DesktopSpace>(x: x, y: y, width: width, height: height)
        return DisplayInfo(
            id: id, frame: frame, pointPixelScale: scale,
            fingerprint: DesktopGeometry.fingerprint(
                id: id, frame: frame, pointPixelScale: scale, rotationDegrees: rotation))
    }

    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recortia-macplatform-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// A private, uniquely named pasteboard. Never the general pasteboard.
    @MainActor
    static func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("recortia.test.\(UUID().uuidString)"))
    }

    static func directoryEntries(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }
}
