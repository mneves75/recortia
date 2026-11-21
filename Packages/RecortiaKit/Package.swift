// swift-tools-version: 6.2
import PackageDescription

// Dependency direction (SPEC.md §6): Domain has no AppKit/SwiftUI/ScreenCaptureKit dependency;
// Imaging depends on Domain; MacPlatform depends on Domain and narrowly on Imaging; Features
// composes them behind small protocols so feature logic is testable without the app.
// RecortiaFixtures is deliberately independent of Imaging so redaction tests never build their
// expected output with the code under test.
let package = Package(
    name: "RecortiaKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Imaging", targets: ["Imaging"]),
        .library(name: "MacPlatform", targets: ["MacPlatform"]),
        .library(name: "Features", targets: ["Features"]),
        .library(name: "RecortiaFixtures", targets: ["RecortiaFixtures"]),
    ],
    // Sparkle (FP-024): the signed updater, an upstream binary target whose checksum its manifest
    // pins at this exact tag. Only `MacPlatform/SparkleUpdateService.swift` imports it.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "Imaging", dependencies: ["Domain"], swiftSettings: [.strictMemorySafety()]),
        .target(
            name: "MacPlatform",
            dependencies: ["Domain", "Imaging", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.strictMemorySafety()]),
        // Main-actor feature models (capture, scroll, export, pins, settings) and the service
        // protocols the composition root fulfils. No AppKit/SwiftUI views live here.
        .target(name: "Features", dependencies: ["Domain", "Imaging", "MacPlatform"]),
        .target(name: "RecortiaFixtures"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "ImagingTests", dependencies: ["Domain", "Imaging", "RecortiaFixtures"]),
        .testTarget(name: "FeaturesTests", dependencies: ["Domain", "Features", "RecortiaFixtures"]),
        .testTarget(
            name: "MacPlatformTests", dependencies: ["Domain", "Imaging", "MacPlatform", "RecortiaFixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
