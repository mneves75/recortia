import Foundation
import Testing

// Failure mode (FP-024): Sparkle spreads beyond its one adapter, so a second file can start an
// updater, read the feed or show Sparkle's windows outside the reviewed boundary and its tests.
// The scan reads every Swift file in the package sources and the app; its planted controls prove
// it can see each way of naming Sparkle.
@Suite("Sparkle stays in its adapter (FP-024)")
struct SparkleImportScanTests {
    static let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let repository = package.deletingLastPathComponent().deletingLastPathComponent()
    static let adapter = "Packages/RecortiaKit/Sources/MacPlatform/SparkleUpdateService.swift"

    static func swiftFiles() throws -> [String: String] {
        var files: [String: String] = [:]
        for root in ["Packages/RecortiaKit/Sources", "RecortiaApp"] {
            let base = repository.appending(path: root)
            let enumerator = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = String(
                    url.path(percentEncoded: false).dropFirst(repository.path(percentEncoded: false).count))
                files[relative] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return files
    }

    @Test("Only the MacPlatform adapter names Sparkle")
    func onlyTheAdapter() throws {
        let files = try Self.swiftFiles()
        #expect(files.count > 100, "the scan found only \(files.count) Swift files")
        let adapter = try #require(files[Self.adapter], "the adapter moved; update the scan")
        #expect(SparkleScan.names(adapter), "the adapter must still import Sparkle, or the scan proves nothing")
        let offenders = files.filter { $0.key != Self.adapter && SparkleScan.names($0.value) }.keys.sorted()
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test("The scan sees every way of naming Sparkle")
    func plantedControls() {
        let planted = [
            "import Sparkle", "@preconcurrency import Sparkle", "@_implementationOnly import Sparkle",
            "import class Sparkle.SPUUpdater", "import struct Sparkle.SUError",
            "let updater: SPUUpdater", "let c = SPUStandardUpdaterController(startingUpdater: false)",
            "extension Delegate: SPUUpdaterDelegate {}", "let item: SUAppcastItem? = nil",
            "if error.domain == SUSparkleErrorDomain {}", "let code = SUError.noUpdateError",
            "let s = Sparkle.SPUUpdaterSettings(hostBundle: .main)",
        ]
        for snippet in planted {
            #expect(SparkleScan.names("import Foundation\n\(snippet)\n"), "scan missed \(snippet)")
        }
        for clean in [
            "// Sparkle and SPUUpdater are named only in a comment", "let sparkleFree = 1",
            "let updates: SparkleUpdateService", "let r = UpdateCheckResult.noUpdate",
        ] {
            #expect(!SparkleScan.names(clean), "false positive: \(clean)")
        }
    }
}

/// Sparkle's module and its public prefixes, over code with line comments stripped. An
/// accidental-regression guard, not a proof against deliberate evasion.
enum SparkleScan {
    static let patterns = [
        #"\bimport\s+(\w+\s+)?Sparkle\b"#, #"\bSparkle\."#, #"\bSPU[A-Z]\w*"#,
        #"\bSU(Appcast|Error|Sparkle|Updater|StandardVersionComparator|VersionComparison|VersionDisplay)\w*"#,
    ]

    static func names(_ source: String) -> Bool {
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
        return patterns.contains { code.range(of: $0, options: .regularExpression) != nil }
    }
}
