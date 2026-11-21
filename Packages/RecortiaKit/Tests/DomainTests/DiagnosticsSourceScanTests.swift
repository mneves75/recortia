import Foundation
import Testing

// Failure modes (B-10, SPEC §7, PRIV-01): the diagnostics sources gain a network API, so the file
// could leave the Mac; `DiagnosticEvent` gains a payload that can carry text, a path, bytes, an
// error message or an arbitrary value, so screen content could reach the file. Each scan has
// planted controls: a scan that finds nothing in them proves nothing.
@Suite("Diagnostics source scan (B-10)")
struct DiagnosticsSourceScanTests {
    static let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every source file that builds, writes or deletes the diagnostics file.
    static let diagnosticsSources = [
        "Sources/Domain/DiagnosticEvent.swift", "Sources/Domain/DiagnosticLine.swift",
        "Sources/MacPlatform/DiagnosticsLog.swift", "Sources/Features/Diagnostics.swift",
    ]

    static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: package.appending(path: relativePath), encoding: .utf8)
    }

    @Test("The diagnostics sources use no network API")
    func noNetwork() throws {
        for path in Self.diagnosticsSources {
            let findings = NetworkScan.findings(in: try Self.source(path))
            #expect(findings.isEmpty, "\(path): \(findings)")
        }
        let planted = [
            "import Network", "@preconcurrency import Network", "import struct Network.NWEndpoint",
            "let c = NWConnection(host: h, port: p, using: .tcp)", "let m = NWPathMonitor()",
            "URLSession.shared.dataTask(with: request)", "let s = URLSession(configuration: .default)",
            "NSURLConnection(request: r, delegate: nil)", "import CFNetwork",
            "CFStreamCreatePairWithSocketToHost(nil, h, 80, &r, &w)",
            "CFSocketCreate(nil, 0, 0, 0, 0, nil, nil)", "let fd = socket(AF_INET, SOCK_STREAM, 0)",
            "connect(fd, &address, length)", "var request = URLRequest(url: url)",
            "let d = try Data(contentsOf: remote)",
            "let t = try String(contentsOf: remote, encoding: .utf8)", "import Darwin", "import Glibc",
            "let stream = OutputStream(url: url, append: true)", "getaddrinfo(host, nil, nil, &info)",
        ]
        for snippet in planted {
            #expect(!NetworkScan.findings(in: "func f() {\n    \(snippet)\n}").isEmpty, "scan missed \(snippet)")
        }
        #expect(NetworkScan.findings(in: "// a URLSession is never used here\nlet x = 1").isEmpty)
    }

    @Test("DiagnosticEvent payloads are only integers, booleans, durations and its own closed types")
    func typedPayloads() throws {
        let findings = PayloadScan.findings(in: try Self.source("Sources/Domain/DiagnosticEvent.swift"))
        #expect(findings.isEmpty, "\(findings)")

        let clean = """
            public enum DiagnosticEvent: Hashable, Sendable {
                case launched(DiagnosticVersion)
                case finished(lines: Int, slow: Bool, duration: Duration)
                case failed(failure: DiagnosticFailure)
            }
            public enum DiagnosticFailure: Hashable, Sendable {
                case denied
                case system(code: Int)
            }
            public struct DiagnosticVersion: Hashable, Sendable {
                public let major: Int
                public init(major: Int) { self.major = major }
            }
            """
        #expect(PayloadScan.findings(in: clean).isEmpty, "\(PayloadScan.findings(in: clean))")
        let planted = [
            "case ocr(text: String)", "case saved(URL)", "case bytes(payload: Data)", "case failed(any Error)",
            "case failed(Error)", "case value(Any)", "case object(AnyObject)", "case name(Substring)",
            "case letter(Character)", "case title(NSString)", "case path(NSURL)", "case key(AnyHashable)",
            "case many(texts: [String])", "case maybe(text: String?)", "case wrapped(Foreign)",
            "case boxed(Box<Int>)", "case some(value: some Sendable)", "case erased(any Sendable)",
            "case pair(count: Int, Foreign)", "case\n    split(\n        count: Int,\n        title: String\n    )",
            "case a, b(text: String)", "case defaulted(text: String = \"\")",
            "case closure(() -> Int)",
        ]
        for snippet in planted {
            let source = "public enum DiagnosticEvent: Hashable, Sendable {\n    \(snippet)\n}"
            #expect(!PayloadScan.findings(in: source).isEmpty, "scan missed \(snippet)")
        }
        let leakingStructs = [
            "public struct DiagnosticVersion { public let title: String }",
            "public struct DiagnosticVersion { var path: URL? }",
            "public struct DiagnosticVersion { public var raw: Foreign }",
            "public enum DiagnosticMode: String { case region }",
        ]
        for snippet in leakingStructs {
            #expect(!PayloadScan.findings(in: clean + "\n" + snippet).isEmpty, "scan missed \(snippet)")
        }
    }
}

/// Network APIs and modules over code with line comments stripped. An accidental-regression
/// guard, not a proof against deliberate evasion.
enum NetworkScan {
    static let patterns = [
        #"\bimport\s+(\w+\s+)?(Network|CFNetwork|Darwin|Glibc)\b"#, #"\bNetwork\."#, #"\bNW[A-Z]\w*"#,
        #"\bURLSession\w*"#, #"\bNSURLConnection\b"#, #"\bURLRequest\b"#, #"\bCF(Stream|Socket|Network|HTTP)\w*"#,
        #"\b(socket|connect|getaddrinfo|bind|sendto|recvfrom)\s*\("#,
        #"\b(Data|String|NSData|NSString)\s*\(\s*contentsOf:"#, #"\b(Input|Output)Stream\b"#,
    ]

    static func findings(in source: String) -> [String] {
        let code = DiagnosticsSourceText.strippingLineComments(source)
        return patterns.filter { code.range(of: $0, options: .regularExpression) != nil }
    }
}

/// Reads every associated-value list and stored property of a declarations-only file and admits
/// only `Int`, `Bool`, `Duration` and the enums and structs that file declares itself.
enum PayloadScan {
    static let primitives: Set<String> = ["Int", "Bool", "Duration"]
    /// Tokens no payload file may contain anywhere, raw-value enums included.
    static let forbidden =
        #"\b(String|Substring|Character|URL|Data|Error|Any|AnyObject|AnyHashable|NS\w+|any|some|Unsafe\w*)\b|<|->|\["#

    static func findings(in source: String) -> [String] {
        let code = DiagnosticsSourceText.strippingLineComments(source)
        var findings: [String] = []
        if let range = code.range(of: forbidden, options: .regularExpression) {
            findings.append("forbidden token \(code[range])")
        }
        let declared = Set(matches(#"\b(?:enum|struct)\s+(\w+)"#, in: code).map { $0[1] })
        let allowed = primitives.union(declared)
        // Every parenthesized list is an associated-value list or an initializer's parameters.
        var types: [String] = []
        for group in matches(#"\(([^()]*)\)"#, in: code) {
            for parameter in group[1].split(separator: ",") {
                let declaration = parameter.split(separator: "=").first.map(String.init) ?? ""
                let type = declaration.split(separator: ":").last.map(String.init) ?? declaration
                types.append(type.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        for property in matches(#"\b(?:let|var)\s+\w+\s*:\s*([^\s{=]+)"#, in: code) {
            types.append(property[1])
        }
        for type in types {
            let bare = type.hasSuffix("?") ? String(type.dropLast()) : type
            if !allowed.contains(bare) { findings.append("payload type '\(type)'") }
        }
        return findings
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [["invalid pattern"]] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map {
                let range = match.range(at: $0)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }
}

enum DiagnosticsSourceText {
    static func strippingLineComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let range = line.range(of: "//") else { return line }
                let prefix = line[..<range.lowerBound]
                // A quote before the slashes may open a string such as a URL: keep the whole line.
                return prefix.contains("\"") ? line : prefix
            }
            .joined(separator: "\n")
    }
}
