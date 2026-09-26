// Renders Framepin's original app icon into the AppIcon asset catalog.
// Usage: xcrun swift scripts/make-icon.swift
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = root.appendingPathComponent("FramepinApp/Resources/Assets.xcassets/AppIcon.appiconset")

func render(size: Int) -> Data? {
    let s = CGFloat(size)
    guard
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // macOS icon grid: 824/1024 body with ~185/1024 corner radius, centered.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = s * 185 / 1024
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 20 / 1024,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(CGColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Viewfinder corner brackets.
    let frame = body.insetBy(dx: s * 150 / 1024, dy: s * 150 / 1024)
    let arm = s * 150 / 1024
    ctx.setStrokeColor(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1))
    ctx.setLineWidth(s * 58 / 1024)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: frame.minX, y: frame.maxY), 1, -1), (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),
        (CGPoint(x: frame.minX, y: frame.minY), 1, 1), (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
    ]
    for (p, dx, dy) in corners {
        ctx.move(to: CGPoint(x: p.x, y: p.y + dy * arm))
        ctx.addLine(to: p)
        ctx.addLine(to: CGPoint(x: p.x + dx * arm, y: p.y))
    }
    ctx.strokePath()

    // Pin head and needle in the center.
    let center = CGPoint(x: body.midX, y: body.midY + s * 40 / 1024)
    let head = s * 118 / 1024
    ctx.setStrokeColor(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1))
    ctx.setLineWidth(s * 34 / 1024)
    ctx.move(to: CGPoint(x: center.x, y: center.y - head * 0.6))
    ctx.addLine(to: CGPoint(x: center.x, y: center.y - head * 2.1))
    ctx.strokePath()
    ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.42, blue: 0.33, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: center.x - head, y: center.y - head, width: 2 * head, height: 2 * head))

    guard let image = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        guard let data = render(size: pixels) else { fatalError("render failed") }
        try data.write(to: iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSet.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icon images to \(iconSet.path)")
