#if DEBUG
    import AppKit
    import SwiftUI

    /// Offscreen hosting and content-only rendering. Windows are parked far outside every display
    /// and never ordered front; pixels come from `cacheDisplay`, never from a screen capture API.
    @MainActor
    enum E2ESnapshot {
        /// Far outside any plausible desktop arrangement.
        static let offscreenOrigin = NSPoint(x: -60_000, y: -60_000)
        /// Screenshots are rendered at 2× regardless of the Mac's displays.
        static let scale: CGFloat = 2
        /// Editor windows use one content size in every scenario so screenshots line up.
        static let editorSize = NSSize(width: 1320, height: 860)

        /// Moves `window` offscreen with a fixed light appearance (deterministic screenshots).
        static func park(_ window: NSWindow) {
            window.appearance = NSAppearance(named: .aqua)
            window.setFrameOrigin(offscreenOrigin)
        }

        /// A borderless offscreen window hosting `view`; `size` nil uses the view's fitting size.
        static func host<Content: View>(_ view: Content, size: NSSize? = nil) -> NSWindow {
            let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light))
            let fitting = size ?? hosting.fittingSize
            return host(nsView: hosting, size: fitting)
        }

        static func host(nsView view: NSView, size: NSSize) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(origin: offscreenOrigin, size: size), styleMask: [.borderless], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            view.frame = NSRect(origin: .zero, size: size)
            window.contentView = view
            park(window)
            return window
        }

        /// Lets SwiftUI and AppKit process pending observation updates, then lays out `view`.
        static func settle(_ view: NSView?, for duration: Duration = .milliseconds(250)) async {
            try? await Task.sleep(for: duration)
            view?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
            view?.layoutSubtreeIfNeeded()
        }

        /// PNG of `view`'s content at 2×, over `background` resolved in the view's appearance.
        static func png(of view: NSView, background: NSColor?) throws -> Data {
            let rep = try bitmap(of: view, background: background)
            guard let srgb = rep.retagging(with: .sRGB), let data = srgb.representation(using: .png, properties: [:])
            else { throw E2EAbort("PNG encoding failed for \(type(of: view))") }
            return data
        }

        /// PNG of `view` drawn over `underlay`, which fills the view's bounds. Used where the app
        /// shows a transparent window above other content (the region overlay above the desktop):
        /// `cacheDisplay` flattens siblings, so the overlay's clear cut-out would erase them.
        static func png(of view: NSView, over underlay: CGImage) throws -> Data {
            let rep = try bitmap(of: view, background: nil)
            guard let overlay = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw E2EAbort("cannot composite \(type(of: view))") }
            let full = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
            context.draw(underlay, in: full)
            context.draw(overlay, in: full)
            guard let image = context.makeImage() else { throw E2EAbort("composite produced no image") }
            return try E2EDrawing.png(image)
        }

        private static func bitmap(of view: NSView, background: NSColor?) throws -> NSBitmapImageRep {
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds
            let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
            guard width > 0, height > 0,
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                    bitsPerPixel: 0)
            else { throw E2EAbort("cannot allocate a \(width)×\(height) bitmap for \(type(of: view))") }
            rep.size = bounds.size
            // List selection is drawn by an NSVisualEffectView whose backdrop does not render through
            // cacheDisplay (it comes out black). Paint the inactive-selection color in its place.
            let selections = EditorWindowController.all(NSVisualEffectView.self, in: view).filter {
                !$0.isHidden && $0.superview is NSTableRowView
            }
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    if let background {
                        background.setFill()
                        NSRect(origin: .zero, size: bounds.size).fill()
                    }
                    NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
                    for selection in selections {
                        var rect = view.convert(selection.bounds, from: selection)
                        if view.isFlipped { rect.origin.y = bounds.height - rect.maxY }
                        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            for selection in selections { selection.isHidden = true }
            view.cacheDisplay(in: bounds, to: rep)
            for selection in selections { selection.isHidden = false }
            return rep
        }
    }
#endif
