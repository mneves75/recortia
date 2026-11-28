// Calibration probe (H3): for each synthetic input, the flat share the encoder would compute and
// the CPU/bytes of ImageIO PNG as RGBA (default), RGB+None and RGB+Sub. Prints one JSON line each.
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import RecortiaFixtures

func cpuNow() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) * 1000 + Double(u.ru_utime.tv_usec) / 1000 + Double(u.ru_stime.tv_sec) * 1000
        + Double(u.ru_stime.tv_usec) / 1000
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// Draws `layers` into an opaque RGBA raster (alpha 255) and returns its bytes.
func raster(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> Data {
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    draw(ctx)
    return Data(bytes: ctx.data!, count: w * h * 4)
}

func image(_ data: Data, _ w: Int, _ h: Int, rgba: Bool) -> CGImage {
    CGImage(
        width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: srgb,
        bitmapInfo: CGBitmapInfo(
            rawValue: (rgba ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func flatShare(_ bytes: Data, width: Int, height: Int) -> Double {
    let span = bytes.span
    var same = 0, total = 0, row = 0
    while row < height {
        let base = row * width * 4
        var i = base + 4
        while i < base + width * 4 {
            if span[i] == span[i - 4], span[i + 1] == span[i - 3], span[i + 2] == span[i - 2] { same += 1 }
            i += 4
        }
        total += width - 1
        row += 8
    }
    return Double(same) / Double(total)
}

func encode(_ img: CGImage, filter: Int?) -> (ms: Double, bytes: Int) {
    var best = Double.infinity
    var size = 0
    for _ in 0..<3 {
        let out = NSMutableData()
        let c0 = cpuNow()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        let props: [CFString: Any] =
            filter.map { [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGCompressionFilter: $0]] } ?? [:]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        best = min(best, cpuNow() - c0)
        size = out.length
    }
    return (best, size)
}

let (W, H) = (2880, 1800)
let screenLight = try SensitiveScreen.render(
    widthPoints: 1440, heightPoints: 900, scale: 2, pointSize: 13, theme: .light, language: .english,
    layout: .denseColumns
).image
let screenDark = try SensitiveScreen.render(
    widthPoints: 1440, heightPoints: 900, scale: 2, pointSize: 13, theme: .dark, language: .english,
    layout: .singleColumn
).image
let photo = try ChartFixture.photographic(width: W, height: H)
let smoothPhoto = try ChartFixture.photographic(width: W, height: H, grain: 0)

func gradient(_ ctx: CGContext, vertical: Bool, _ rect: CGRect) {
    let g = CGGradient(
        colorsSpace: srgb,
        colors: [CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1), CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1)]
            as CFArray, locations: nil)!
    ctx.saveGState()
    ctx.clip(to: rect)
    ctx.drawLinearGradient(
        g, start: CGPoint(x: rect.minX, y: rect.minY),
        end: vertical ? CGPoint(x: rect.minX, y: rect.maxY) : CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()
}

var cases: [(String, (CGContext) -> Void)] = [
    ("screen_light_dense", { $0.draw(screenLight, in: CGRect(x: 0, y: 0, width: W, height: H)) }),
    ("screen_dark_single", { $0.draw(screenDark, in: CGRect(x: 0, y: 0, width: W, height: H)) }),
    ("photo_grain12", { $0.draw(photo, in: CGRect(x: 0, y: 0, width: W, height: H)) }),
    ("photo_smooth", { $0.draw(smoothPhoto, in: CGRect(x: 0, y: 0, width: W, height: H)) }),
    ("gradient_vertical", { gradient($0, vertical: true, CGRect(x: 0, y: 0, width: W, height: H)) }),
    ("gradient_horizontal", { gradient($0, vertical: false, CGRect(x: 0, y: 0, width: W, height: H)) }),
]
for share in [0.25, 0.4, 0.5, 0.6, 0.75] {
    // A UI screen with one embedded photo covering `share` of its area (a web page, a viewer).
    cases.append((
        "screen_photo_\(Int(share * 100))",
        { ctx in
            ctx.draw(screenLight, in: CGRect(x: 0, y: 0, width: W, height: H))
            let side = sqrt(share)
            ctx.draw(photo, in: CGRect(x: 0, y: 0, width: Double(W) * side, height: Double(H) * side))
        }
    ))
    cases.append((
        "dark_gradient_\(Int(share * 100))",
        { ctx in
            ctx.draw(screenDark, in: CGRect(x: 0, y: 0, width: W, height: H))
            gradient(ctx, vertical: false, CGRect(x: 0, y: 0, width: Double(W) * share, height: Double(H)))
        }
    ))
}
/// Among sampled pixels that differ from their left neighbor, the share whose largest channel step is at most `limit`.
func smoothShare(_ bytes: Data, width: Int, height: Int, limit: Int) -> Double {
    let span = bytes.span
    var small = 0, differ = 0, row = 0
    while row < height {
        let base = row * width * 4
        var i = base + 4
        while i < base + width * 4 {
            let d0 = abs(Int(span[i]) - Int(span[i - 4])), d1 = abs(Int(span[i + 1]) - Int(span[i - 3]))
            let d2 = abs(Int(span[i + 2]) - Int(span[i - 2]))
            let m = max(d0, d1, d2)
            if m > 0 { differ += 1; if m <= limit { small += 1 } }
            i += 4
        }
        row += 8
    }
    return differ == 0 ? 0 : Double(small) / Double(differ)
}
if CommandLine.arguments.dropFirst().first == "stats" {
    for (name, draw) in cases {
        let data = raster(W, H, draw)
        let f = flatShare(data, width: W, height: H)
        let s2 = smoothShare(data, width: W, height: H, limit: 2), s4 = smoothShare(data, width: W, height: H, limit: 4)
        let s8 = smoothShare(data, width: W, height: H, limit: 8)
        print(name, "flat", (f * 1000).rounded() / 1000, "s2", (s2 * 1000).rounded() / 1000, "s4", (s4 * 1000).rounded() / 1000, "s8", (s8 * 1000).rounded() / 1000)
    }
    exit(0)
}
let only = CommandLine.arguments.dropFirst()
for (name, draw) in cases where only.isEmpty || only.contains(name) {
    let data = raster(W, H, draw)
    let flat = flatShare(data, width: W, height: H)
    let rgba = encode(image(data, W, H, rgba: true), filter: nil)
    let none = encode(image(data, W, H, rgba: false), filter: 0x08)
    let sub = encode(image(data, W, H, rgba: false), filter: 0x10)
    let up = encode(image(data, W, H, rgba: false), filter: 0x20)
    let paeth = encode(image(data, W, H, rgba: false), filter: 0x80)
    let line: [String: Any] = [
        "case": name, "flat": (flat * 1000).rounded() / 1000,
        "rgba_ms": rgba.ms.rounded(), "rgba_b": rgba.bytes,
        "none_ms": none.ms.rounded(), "none_b": none.bytes,
        "sub_ms": sub.ms.rounded(), "sub_b": sub.bytes,
        "up_ms": up.ms.rounded(), "up_b": up.bytes, "paeth_ms": paeth.ms.rounded(), "paeth_b": paeth.bytes,
    ]
    let json = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
    print(String(decoding: json, as: UTF8.self))
}
