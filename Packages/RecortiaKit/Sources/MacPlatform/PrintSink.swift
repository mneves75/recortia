import AppKit
import Domain

/// Builds the print operation for a sanitized snapshot (B-9a): one image view showing the
/// snapshot's own PNG bytes at the output's pixel size, fit to the page and centred, with the
/// standard print panel and its Preview and PDF options. Nothing else reaches it: no raster, no
/// document, no window contents.
public enum PrintSink {
    @MainActor
    public static func operation(for snapshot: ShareSnapshot) throws(SinkError) -> NSPrintOperation {
        guard snapshot.format == .png, !snapshot.pixelSize.isEmpty,
            snapshot.bytes.starts(with: ClipboardSink.pngSignature),
            let representation = NSBitmapImageRep(data: snapshot.bytes),
            representation.pixelsWide == snapshot.pixelSize.width,
            representation.pixelsHigh == snapshot.pixelSize.height
        else { throw .printFailed }
        let size = NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageFrameStyle = .none

        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.orientation = size.width > size.height ? .landscape : .portrait
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.jobTitle = URL(fileURLWithPath: snapshot.suggestedFilename).deletingPathExtension().lastPathComponent
        operation.printPanel.options.formUnion([.showsPreview, .showsOrientation, .showsPaperSize, .showsScaling])
        return operation
    }
}
