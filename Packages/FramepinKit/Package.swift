// swift-tools-version: 6.2
import PackageDescription

// Dependency direction (SPEC.md §6): Domain has no AppKit/SwiftUI/ScreenCaptureKit dependency;
// Imaging depends on Domain; MacPlatform depends on Domain and narrowly on Imaging.
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
        .library(name: "FramepinFixtures", targets: ["FramepinFixtures"]),
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "Imaging", dependencies: ["Domain"]),
        .target(name: "MacPlatform", dependencies: ["Domain", "Imaging"]),
        .target(name: "FramepinFixtures"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "ImagingTests", dependencies: ["Domain", "Imaging", "FramepinFixtures"]),
        .testTarget(
            name: "MacPlatformTests", dependencies: ["Domain", "Imaging", "MacPlatform", "FramepinFixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
