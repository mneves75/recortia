// swift-tools-version: 6.2
// Frozen perf harness for the 2026-11 hillclimb (docs/specs/performance-2026-11). Never shipped:
// no app target or gate depends on it. Synthetic RecortiaFixtures inputs only.
import PackageDescription

let package = Package(
    name: "RecortiaBench",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../../../Packages/RecortiaKit")],
    targets: [
        .executableTarget(
            name: "bench",
            dependencies: [
                .product(name: "Domain", package: "RecortiaKit"),
                .product(name: "Imaging", package: "RecortiaKit"),
                .product(name: "Features", package: "RecortiaKit"),
                .product(name: "RecortiaFixtures", package: "RecortiaKit"),
            ]),
        // Calibration probe for the PNG row-filter choice (H3); not a scored scenario.
        .executableTarget(
            name: "probe",
            dependencies: [.product(name: "RecortiaFixtures", package: "RecortiaKit")]),
    ]
)
