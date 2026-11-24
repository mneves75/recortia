import Foundation
import Testing

// Failure mode (AGENTS.md boundaries): Domain pulls in AppKit/UI/system frameworks, production
// code introduces unguarded crash paths or NSScreen.main, or RecortiaApp bypasses AppPresence /
// FilePanelPresenter with bare NSApp.activate() or file-panel .runModal().
@Suite("Static architecture boundary scanner (AGENTS.md)")
struct ArchitectureBoundaryScanTests {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let allowedDomainImports: Set<String> = ["Foundation", "Synchronization"]
    static let allowedBareActivateFiles: Set<String> = [
        "RecortiaApp/App/AppPresence.swift",
        "RecortiaApp/App/CaptureMenu.swift",
        "RecortiaApp/Capture/HostingPanel.swift",
    ]
    static let allowedFilePanelModalFiles: Set<String> = [
        "RecortiaApp/App/FilePanelPresenter.swift"
    ]

    static func swiftFiles(under root: String, excluding excludedPrefixes: [String] = []) throws -> [String: String] {
        let base = repository.appending(path: root)
        let rootPrefix = repository.path(percentEncoded: false)
        let prefixWithSlash = rootPrefix.hasSuffix("/") ? rootPrefix : rootPrefix + "/"
        let enumerator = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
        var files: [String: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let full = url.path(percentEncoded: false)
            let relative = full.hasPrefix(prefixWithSlash) ? String(full.dropFirst(prefixWithSlash.count)) : full
            if excludedPrefixes.contains(where: { relative.hasPrefix($0) }) { continue }
            files[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        return files
    }

    @Test("Domain imports only Foundation and Synchronization")
    func domainImportsStayPure() throws {
        let files = try Self.swiftFiles(under: "Packages/RecortiaKit/Sources/Domain")
        #expect(files.count >= 15, "expected Domain sources, found \(files.count)")
        var violations: [String] = []
        for (path, source) in files.sorted(by: { $0.key < $1.key }) {
            let forbidden = ArchitectureBoundaryScanner.forbiddenDomainImports(
                in: source, allowed: Self.allowedDomainImports)
            if !forbidden.isEmpty {
                violations.append("\(path): \(forbidden.joined(separator: ", "))")
            }
        }
        #expect(violations.isEmpty, "forbidden Domain imports: \(violations)")
    }

    @Test("Production sources contain no fatalError, preconditionFailure, try!, or NSScreen.main")
    func noForbiddenCrashOrMainScreenAPIs() throws {
        var files = try Self.swiftFiles(under: "Packages/RecortiaKit/Sources")
        files.merge(try Self.swiftFiles(under: "RecortiaApp", excluding: ["RecortiaApp/E2E/"])) { _, new in new }
        #expect(files.count > 100, "expected production Swift files, found \(files.count)")
        var violations: [String] = []
        for (path, source) in files.sorted(by: { $0.key < $1.key }) {
            let hits = ArchitectureBoundaryScanner.forbiddenProductionTokens(in: source)
            if !hits.isEmpty {
                violations.append("\(path): \(hits.joined(separator: ", "))")
            }
        }
        #expect(violations.isEmpty, "forbidden production tokens: \(violations)")
    }

    @Test("Bare NSApp.activate stays confined to the reviewed allowlist")
    func bareActivateStaysInAllowlist() throws {
        let files = try Self.swiftFiles(under: "RecortiaApp", excluding: ["RecortiaApp/E2E/"])
        #expect(!files.isEmpty)
        for allowed in Self.allowedBareActivateFiles.sorted() {
            let source = try #require(files[allowed], "allowlisted file moved: \(allowed)")
            #expect(
                ArchitectureBoundaryScanner.containsBareNSAppActivate(source),
                "positive control: \(allowed) no longer calls NSApp.activate(")
        }
        let offenders = files.filter {
            !Self.allowedBareActivateFiles.contains($0.key)
                && ArchitectureBoundaryScanner.containsBareNSAppActivate($0.value)
        }.keys.sorted()
        #expect(offenders.isEmpty, "unreviewed NSApp.activate(: \(offenders)")
    }

    @Test("NSOpenPanel and NSSavePanel never call bare .runModal() outside FilePanelPresenter")
    func filePanelsAvoidBareRunModal() throws {
        let files = try Self.swiftFiles(under: "RecortiaApp", excluding: ["RecortiaApp/E2E/"])
        #expect(!files.isEmpty)
        let offenders = files.filter {
            !Self.allowedFilePanelModalFiles.contains($0.key)
                && ArchitectureBoundaryScanner.containsBareFilePanelRunModal($0.value)
        }.keys.sorted()
        #expect(offenders.isEmpty, "unreviewed file panel .runModal(): \(offenders)")
    }

    @Test("Planted controls prove every rule catches real violations and ignores comments")
    func plantedControls() {
        let forbiddenImports = [
            "import AppKit", "@preconcurrency import SwiftUI", "@_implementationOnly import CoreGraphics",
            "import class AppKit.NSFont", "import ScreenCaptureKit", "import Network",
            "import Vision", "import ImageIO", "import Sparkle",
        ]
        for snippet in forbiddenImports {
            let found = ArchitectureBoundaryScanner.forbiddenDomainImports(
                in: "import Foundation\n\(snippet)\n", allowed: Self.allowedDomainImports)
            #expect(!found.isEmpty, "domain import scan missed: \(snippet)")
        }
        let cleanDomain = """
            // import AppKit
            /* import SwiftUI
               /* nested import CoreGraphics */
               import Sparkle
            */
            import Foundation
            import Synchronization
            """
        #expect(
            ArchitectureBoundaryScanner.forbiddenDomainImports(
                in: cleanDomain, allowed: Self.allowedDomainImports
            ).isEmpty)

        let forbiddenTokens = [
            #"fatalError("boom")"#,
            #"preconditionFailure("bad")"#,
            "let x = try! risky()",
            "let s = NSScreen.main",
            #"let url = "https://example.com"; fatalError("after url")"#,
            "/* outer /* inner */ still comment */ let y = try! parse()",
        ]
        for snippet in forbiddenTokens {
            #expect(
                !ArchitectureBoundaryScanner.forbiddenProductionTokens(in: snippet).isEmpty,
                "token scan missed: \(snippet)")
        }
        let cleanTokens = """
            // fatalError("comment") try! NSScreen.main
            /// preconditionFailure("doc")
            /* fatalError("block")
               /* nested try! NSScreen.main */
               preconditionFailure("still block")
            */
            let ok = try? safe()
            let label = "not a crash"
            """
        #expect(ArchitectureBoundaryScanner.forbiddenProductionTokens(in: cleanTokens).isEmpty)

        #expect(ArchitectureBoundaryScanner.containsBareNSAppActivate("NSApp.activate()"))
        #expect(ArchitectureBoundaryScanner.containsBareNSAppActivate("NSApp.activate(ignoringOtherApps: true)"))
        #expect(!ArchitectureBoundaryScanner.containsBareNSAppActivate("// NSApp.activate()"))
        #expect(!ArchitectureBoundaryScanner.containsBareNSAppActivate("/* NSApp.activate() */"))
        #expect(!ArchitectureBoundaryScanner.containsBareNSAppActivate("AppPresence.shared.activate()"))

        let plantedModal = """
            let panel = NSSavePanel()
            if panel.runModal() == .OK { print(panel.url as Any) }
            """
        let plantedOpenModal = """
            let panel = NSOpenPanel()
            _ = panel.runModal()
            """
        #expect(ArchitectureBoundaryScanner.containsBareFilePanelRunModal(plantedModal))
        #expect(ArchitectureBoundaryScanner.containsBareFilePanelRunModal(plantedOpenModal))
        let cleanAlertModal = """
            let alert = NSAlert()
            _ = alert.runModal()
            """
        let cleanPrintModal = """
            let panel = NSSavePanel()
            // panel.runModal()
            /* panel.runModal() */
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            panel.begin { _ in }
            """
        #expect(!ArchitectureBoundaryScanner.containsBareFilePanelRunModal(cleanAlertModal))
        #expect(!ArchitectureBoundaryScanner.containsBareFilePanelRunModal(cleanPrintModal))
    }
}

/// Lexer-aware Swift comment stripper and boundary matchers. Strips `//` and nested `/* ... */`
/// comments while preserving string literals so `//` inside URLs does not mask trailing code.
enum ArchitectureBoundaryScanner {
    static let importPattern =
        #"(?m)^\s*(?:@\w+\s+)*import\s+"#
        + #"(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_][A-Za-z0-9_]*)"#
    static let forbiddenTokenRules: [(label: String, pattern: String)] = [
        ("fatalError(", #"\bfatalError\s*\("#),
        ("preconditionFailure(", #"\bpreconditionFailure\s*\("#),
        ("try!", #"\btry!"#),
        ("NSScreen.main", #"\bNSScreen\s*\.\s*main\b"#),
    ]

    static func stripComments(_ source: String) -> String {
        let chars = Array(source)
        let count = chars.count
        var output: [Character] = []
        output.reserveCapacity(count)
        var i = 0
        var blockDepth = 0
        var inLineComment = false

        while i < count {
            if inLineComment {
                if chars[i] == "\n" {
                    inLineComment = false
                    output.append("\n")
                }
                i += 1
                continue
            }
            if blockDepth > 0 {
                if i + 1 < count, chars[i] == "/", chars[i + 1] == "*" {
                    blockDepth += 1
                    i += 2
                } else if i + 1 < count, chars[i] == "*", chars[i + 1] == "/" {
                    blockDepth -= 1
                    output.append(" ")
                    i += 2
                } else {
                    if chars[i] == "\n" { output.append("\n") }
                    i += 1
                }
                continue
            }
            if i + 1 < count, chars[i] == "/", chars[i + 1] == "/" {
                inLineComment = true
                i += 2
                continue
            }
            if i + 1 < count, chars[i] == "/", chars[i + 1] == "*" {
                blockDepth = 1
                i += 2
                continue
            }
            if chars[i] == "#" || chars[i] == "\"" {
                if let next = copyStringLiteral(chars, from: i, into: &output) {
                    i = next
                    continue
                }
            }
            output.append(chars[i])
            i += 1
        }
        return String(output)
    }

    private static func copyStringLiteral(
        _ chars: [Character], from start: Int, into output: inout [Character]
    ) -> Int? {
        let count = chars.count
        var hashes = 0
        var i = start
        while i < count, chars[i] == "#" {
            hashes += 1
            i += 1
        }
        guard i < count, chars[i] == "\"" else { return nil }
        let multiline = i + 2 < count && chars[i + 1] == "\"" && chars[i + 2] == "\""
        let quoteLength = multiline ? 3 : 1
        let openingEnd = i + quoteLength
        output.append(contentsOf: chars[start..<openingEnd])
        i = openingEnd

        while i < count {
            if chars[i] == "\\" {
                let escapeEnd = i + 1 + hashes
                if escapeEnd < count,
                    (hashes == 0 || chars[(i + 1)..<escapeEnd].allSatisfy { $0 == "#" })
                {
                    output.append(contentsOf: chars[i...escapeEnd])
                    i = escapeEnd + 1
                    continue
                }
            }
            if i + quoteLength + hashes <= count,
                chars[i..<(i + quoteLength)].allSatisfy({ $0 == "\"" }),
                (hashes == 0 || chars[(i + quoteLength)..<(i + quoteLength + hashes)].allSatisfy({ $0 == "#" }))
            {
                let closeEnd = i + quoteLength + hashes
                output.append(contentsOf: chars[i..<closeEnd])
                return closeEnd
            }
            output.append(chars[i])
            i += 1
        }
        return i
    }

    static func forbiddenDomainImports(in source: String, allowed: Set<String>) -> [String] {
        let code = stripComments(source)
        guard let regex = try? NSRegularExpression(pattern: importPattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        var forbidden: [String] = []
        for match in regex.matches(in: code, range: range) {
            guard let moduleRange = Range(match.range(at: 1), in: code) else { continue }
            let module = String(code[moduleRange])
            if !allowed.contains(module) {
                forbidden.append(module)
            }
        }
        return forbidden
    }

    static func forbiddenProductionTokens(in source: String) -> [String] {
        let code = stripComments(source)
        return forbiddenTokenRules.compactMap { rule in
            code.range(of: rule.pattern, options: .regularExpression) != nil ? rule.label : nil
        }
    }

    static func containsBareNSAppActivate(_ source: String) -> Bool {
        let code = stripComments(source)
        return code.range(of: #"\bNSApp\s*\.\s*activate\s*\("#, options: .regularExpression) != nil
    }

    static func containsBareFilePanelRunModal(_ source: String) -> Bool {
        let code = stripComments(source)
        let usesFilePanel =
            code.range(of: #"\b(?:NSOpenPanel|NSSavePanel)\b"#, options: .regularExpression) != nil
        guard usesFilePanel else { return false }
        return code.range(of: #"\.\s*runModal\s*\(\s*\)"#, options: .regularExpression) != nil
    }
}
