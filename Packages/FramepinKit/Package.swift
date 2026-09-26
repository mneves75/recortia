// swift-tools-version: 6.2
import PackageDescription

// Dependency direction (SPEC.md §6): Domain has no AppKit/SwiftUI/ScreenCaptureKit dependency;
// Imaging depends on Domain; MacPlatform depends on Domain and narrowly on Imaging; Features
// composes them behind small protocols so feature logic is testable without the app.
// FramepinFixtures is deliberately independent of Imaging so redaction tests never build their
// expected output with the code under test.
let package = Package(
    name: "FramepinKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Imaging", targets: ["Imaging"]),
        .library(name: "MacPlatform", targets: ["MacPlatform"]),
        .library(name: "Features", targets: ["Features"]),
        .library(name: "FramepinFixtures", targets: ["FramepinFixtures"]),
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "Imaging", dependencies: ["Domain"]),
        .target(name: "MacPlatform", dependencies: ["Domain", "Imaging"]),
        // Main-actor feature models (capture, scroll, export, pins, settings) and the service
        // protocols the composition root fulfils. No AppKit/SwiftUI views live here.
        .target(name: "Features", dependencies: ["Domain", "Imaging", "MacPlatform"]),
        .target(name: "FramepinFixtures"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "ImagingTests", dependencies: ["Domain", "Imaging", "FramepinFixtures"]),
        .testTarget(name: "FeaturesTests", dependencies: ["Domain", "Features", "FramepinFixtures"]),
        .testTarget(
            name: "MacPlatformTests", dependencies: ["Domain", "Imaging", "MacPlatform", "FramepinFixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
