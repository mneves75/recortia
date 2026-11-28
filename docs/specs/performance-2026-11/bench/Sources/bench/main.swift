// Frozen benchmark harness (hillclimb 2026-11). One scenario per process so the lifetime peak
// footprint belongs to that scenario. Prints one JSON line.
// Usage: bench <scenario> [iterations]
import CoreGraphics
import Darwin
import Domain
import Features
import Foundation
import Imaging
import RecortiaFixtures

struct Sample { var cpuMs: Double; var wallMs: Double }

func cpuNow() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    let user = Double(u.ru_utime.tv_sec) * 1000 + Double(u.ru_utime.tv_usec) / 1000
    let sys = Double(u.ru_stime.tv_sec) * 1000 + Double(u.ru_stime.tv_usec) / 1000
    return user + sys
}

func footprint() -> (current: Double, peak: Double) {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    guard ok == 0 else { return (0, 0) }
    return (Double(info.ri_phys_footprint) / 1_048_576, Double(info.ri_lifetime_max_phys_footprint) / 1_048_576)
}

func measure(_ n: Int, _ body: () async throws -> Void) async throws -> [Sample] {
    try await body()  // warm-up
    var out: [Sample] = []
    for _ in 0..<n {
        let c0 = cpuNow()
        let t0 = ContinuousClock.now
        try await body()
        let wall = ContinuousClock.now - t0
        let ms = Double(wall.components.seconds) * 1000 + Double(wall.components.attoseconds) / 1e15
        out.append(Sample(cpuMs: cpuNow() - c0, wallMs: ms))
    }
    return out
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

// MARK: Fixtures (deterministic)

let screenImage: CGImage = try! SensitiveScreen.render(
    widthPoints: 2560, heightPoints: 1440, scale: 2, pointSize: 13, theme: .light,
    language: .english, layout: .denseColumns
).image  // 5120 × 2880, text-dense UI, like a Retina 5K capture

func annotations(_ w: Double, _ h: Double) -> [Annotation] {
    let red = Annotation.Style(stroke: RGBA(r: 255, g: 40, b: 40), lineWidth: 6, opacity: 1)
    return [
        Annotation(kind: .arrow(start: Point(x: w * 0.1, y: h * 0.2), end: Point(x: w * 0.4, y: h * 0.35)), style: red),
        Annotation(
            kind: .arrow(
                start: Point(x: w * 0.6, y: h * 0.8), end: Point(x: w * 0.8, y: h * 0.5),
                control: Point(x: w * 0.75, y: h * 0.75)), style: red),
        Annotation(kind: .rectangle(Rect(x: w * 0.2, y: h * 0.5, width: w * 0.2, height: h * 0.1)), style: red),
        Annotation(kind: .ellipse(Rect(x: w * 0.55, y: h * 0.15, width: w * 0.15, height: h * 0.1)), style: red),
        Annotation(
            kind: .text(.init(origin: Point(x: w * 0.1, y: h * 0.7), string: "Review this value", fontSize: 48)),
            style: red),
        Annotation(kind: .step(center: Point(x: w * 0.9, y: h * 0.1), number: 1), style: red),
    ]
}

func masks(_ w: Double, _ h: Double) -> [Rect<DocumentSpace>] {
    [
        Rect(x: w * 0.05, y: h * 0.05, width: w * 0.25, height: 60),
        Rect(x: w * 0.5, y: h * 0.4, width: w * 0.3, height: 120),
        Rect(x: w * 0.3, y: h * 0.85, width: w * 0.4, height: 80),
    ]
}

struct Env {
    let store = ImageStore()
    var renderer: PrivacyRenderer { PrivacyRenderer(store: store) }
    var pipeline: ExportPipeline { ExportPipeline(renderer: renderer) }
    func session(_ image: CGImage, annotated: Bool, masked: Bool) async throws -> DocumentSession {
        let asset = await store.insert(try ImageDecoder.canonicalize(image), origin: .imported)
        var document = Document(asset: asset)
        let w = Double(asset.pixelSize.width), h = Double(asset.pixelSize.height)
        if annotated { document.annotations = annotations(w, h) }
        var session = DocumentSession(document: document)
        if masked { for r in masks(w, h) { _ = try session.addSecureMask(covering: r) } }
        return session
    }
}

let exportDate = Date(timeIntervalSince1970: 1_790_000_000)

// MARK: Scenarios

let args = CommandLine.arguments
let scenario = args.count > 1 ? args[1] : "list"
let iterations = args.count > 2 ? Int(args[2])! : 5
var extra: [String: Double] = [:]
let env = Env()
var samples: [Sample] = []
var setup: (current: Double, peak: Double) = (0, 0)

switch scenario {
case "render_base_5k", "render_base_5k_masked":
    let s = try await env.session(screenImage, annotated: false, masked: scenario.hasSuffix("masked"))
    setup = footprint()
    samples = try await measure(iterations) { _ = try await env.renderer.renderBase(s.document, scale: 1) }
case "export_png_5k", "export_auto_5k", "export_heic_5k":
    let s = try await env.session(screenImage, annotated: true, masked: true)
    let options: ExportOptions =
        scenario == "export_auto_5k"
        ? ExportOptions(automaticFormat: true) : ExportOptions(format: scenario == "export_heic_5k" ? .heic(quality: 0.8) : .png)
    setup = footprint()
    var bytes = 0
    samples = try await measure(iterations) {
        bytes = try await env.pipeline.snapshot(of: s, options: options, date: exportDate).bytes.count
    }
    extra["bytes"] = Double(bytes)
case "export_png_photo":
    let photo = try ChartFixture.photographic(width: 3024, height: 1964)
    let s = try await env.session(photo, annotated: true, masked: true)
    setup = footprint()
    var bytes = 0
    samples = try await measure(iterations) {
        bytes = try await env.pipeline.snapshot(of: s, options: ExportOptions(), date: exportDate).bytes.count
    }
    extra["bytes"] = Double(bytes)
case "decode_png_5k":
    let s = try await env.session(screenImage, annotated: false, masked: false)
    let png = try await env.pipeline.snapshot(of: s, options: ExportOptions(), date: exportDate).bytes
    setup = footprint()
    samples = try await measure(iterations) { _ = try ImageDecoder.decode(png) }
    extra["bytes_in"] = Double(png.count)
case "canvas_draw_5k":
    // One editor frame: the 5K document fitted into a 1440×810 pt view at 2× backing.
    let s = try await env.session(screenImage, annotated: true, masked: true)
    let base = try await env.renderer.renderBase(s.document, scale: 1)
    let (vw, vh) = (2880, 1620)
    let ctx = CGContext(
        data: nil, width: vw, height: vh, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let zoom = Double(vw) / Double(base.width)
    ctx.translateBy(x: 0, y: CGFloat(vh))
    ctx.scaleBy(x: zoom, y: -zoom)
    setup = footprint()
    let frames = 20
    samples = try await measure(iterations) {
        for _ in 0..<frames {
            try EditorCanvasRenderer.draw(s.document, base: base, calloutBase: base, in: ctx)
        }
    }
    samples = samples.map { Sample(cpuMs: $0.cpuMs / Double(frames), wallMs: $0.wallMs / Double(frames)) }
case "scan_sensitive_5k":
    let asset = await env.store.insert(try ImageDecoder.canonicalize(screenImage), origin: .imported)
    setup = footprint()
    var found = 0
    samples = try await measure(iterations) {
        found = try await SensitiveTextScanner().sensitiveRegions(
            of: asset.id, in: env.store, pixelsPerPoint: 2, languages: [Locale.Language(identifier: "en-US")]
        ).count
    }
    extra["regions"] = Double(found)
default:
    print(
        "scenarios: render_base_5k render_base_5k_masked export_png_5k export_auto_5k export_heic_5k export_png_photo decode_png_5k canvas_draw_5k scan_sensitive_5k"
    )
    exit(0)
}

let fp = footprint()
var result: [String: Any] = [
    "scenario": scenario, "n": samples.count,
    "cpu_ms_median": median(samples.map(\.cpuMs)), "wall_ms_median": median(samples.map(\.wallMs)),
    "cpu_ms_min": samples.map(\.cpuMs).min()!, "wall_ms_min": samples.map(\.wallMs).min()!,
    "peak_footprint_mb": fp.peak, "peak_over_setup_mb": max(0, fp.peak - setup.current), "setup_peak_mb": setup.peak,
]
for (k, v) in extra { result[k] = v }
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
