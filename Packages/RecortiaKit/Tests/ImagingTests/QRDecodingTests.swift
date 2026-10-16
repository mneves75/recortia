import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

@Suite("OCR-02: QR payload safety")
struct QRDecodingTests {
    let decoder = QRDecoder()

    static func matches(_ kind: QRPayload.Kind, _ expected: QRFixture.ExpectedKind) -> Bool {
        switch (kind, expected) {
        case (.text, .text), (.wifi, .wifi), (.payment, .payment), (.binary, .binary): true
        case (.webURL(let url), .webURL(let string)): url.absoluteString == string
        case (.otherScheme(let scheme), .otherScheme(let expectedScheme)): scheme == expectedScheme
        default: false
        }
    }

    @Test("Every fixture decodes to its exact message bytes and conservative kind", arguments: try QRFixture.all())
    func fixtureBytesAndKinds(_ fixture: QRFixture) async throws {
        let payloads = try await decoder.decode(fixture.image)
        #expect(payloads.map(\.bytes) == fixture.expectedPayloads, "\(fixture.name)")
        guard payloads.count == fixture.expectedKinds.count else { return }
        for (payload, expected) in zip(payloads, fixture.expectedKinds) {
            #expect(Self.matches(payload.kind, expected), "\(fixture.name): \(payload.kind) vs \(expected)")
            if case .binary = expected {
                #expect(payload.string == nil)
            } else {
                #expect(payload.string.map { Data($0.utf8) } == payload.bytes, "\(fixture.name)")
            }
        }
    }

    @Test("Classification is conservative: only well-formed http(s) with a host is a web URL")
    func classification() {
        func kind(_ string: String) -> QRPayload.Kind { QRPayloadClassifier.classify(Data(string.utf8)).kind }
        #expect(kind("https://example.com") == .webURL(URL(string: "https://example.com")!))
        #expect(kind("HTTP://EXAMPLE.COM/") == .webURL(URL(string: "HTTP://EXAMPLE.COM/")!))
        #expect(kind("https://exa mple.com") == .otherScheme("https"))
        #expect(kind("https://") == .otherScheme("https"))
        #expect(kind("http:no-host") == .otherScheme("http"))
        #expect(kind(" https://example.com") == .otherScheme("https"))
        #expect(kind("javascript:alert(1)") == .otherScheme("javascript"))
        #expect(kind("JavaScript:alert(1)") == .otherScheme("javascript"))
        #expect(kind("file:///Users/x/.ssh/id_ed25519") == .otherScheme("file"))
        #expect(
            kind("x-apple.systempreferences:com.apple.preference.security") == .otherScheme("x-apple.systempreferences")
        )
        #expect(kind("tel:+5511999999999") == .otherScheme("tel"))
        // User info disguises the real host: never a web URL.
        #expect(kind("https://trusted@evil.example") == .otherScheme("https"))
        #expect(kind("https://trusted.example@evil.example/login") == .otherScheme("https"))
        #expect(kind("http://user:pass@example.com/") == .otherScheme("http"))
        #expect(kind("https://:pw@example.com") == .otherScheme("https"))
        #expect(kind("https://@example.com") == .otherScheme("https"))
        #expect(kind("WIFI:S:net;T:WPA;P:pw;;") == .wifi)
        #expect(kind("wifi:S:net;;") == .wifi)
        #expect(kind("bitcoin:bc1qxyz?amount=1") == .payment)
        #expect(kind("lightning:lnbc1u1p") == .payment)
        #expect(kind("000201010211") == .payment)
        #expect(kind("Hello world") == .text)
        #expect(kind("12:30 meeting") == .text)
        #expect(kind("") == .text)
        let invalidUTF8 = QRPayloadClassifier.classify(Data([0xC3, 0x28]))
        #expect(invalidUTF8.kind == .binary)
        #expect(invalidUTF8.string == nil)
    }

    static func hex(_ string: String) -> Data {
        var data = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index..<next], radix: 16) ?? 0)
            index = next
        }
        return data
    }

    @Test("Recovered bytes must match Vision's decoded string when Vision reports one")
    func bitstreamAgreesWithVisionString() {
        let helloWorld = Self.hex("40b68656c6c6f20776f726c640ec11ec")
        #expect(
            QRBitstream.messageBytes(fromDataCodewords: helloWorld, expectedString: "hello world")
                == Data("hello world".utf8))
        // A unique parse that differs from what other scanners show is dropped, not returned.
        #expect(QRBitstream.messageBytes(fromDataCodewords: helloWorld, expectedString: "hello w0rld") == nil)
        #expect(QRBitstream.messageBytes(fromDataCodewords: helloWorld, expectedString: "") == nil)
        // Bytes that are not UTF-8 (Shift JIS from Kanji mode, an ECI charset) cannot be compared
        // with Vision's string, and cannot become a link either: they are kept as binary payloads
        // (Codex review: dropping them lost legitimate Kanji and ECI codes).
        let binary = Self.hex("405fffe0080410ec11ec11ec11ec11ec")
        #expect(QRBitstream.messageBytes(fromDataCodewords: binary, expectedString: "ÿþ\u{0}\u{80}A") != nil)
        #expect(QRBitstream.messageBytes(fromDataCodewords: binary, expectedString: nil) != nil)
    }

    @Test("Bitstream parser rejects truncated or invalid segments")
    func bitstreamRejectsGarbage() {
        // Byte mode announcing 11 bytes with only 2 present.
        #expect(QRBitstream.messageBytes(fromDataCodewords: Self.hex("40b686"), expectedString: nil) == nil)
        // Numeric group 999 is valid, 1023 is not: 0001 | count 3 | 1111111111.
        #expect(QRBitstream.messageBytes(fromDataCodewords: Self.hex("100ffff0"), expectedString: nil) == nil)
        // Reserved mode indicator 0110.
        #expect(QRBitstream.messageBytes(fromDataCodewords: Self.hex("60000000"), expectedString: nil) == nil)
        #expect(QRBitstream.messageBytes(fromDataCodewords: Data(), expectedString: nil) == nil)
    }

    @Test("Imaging never opens, fetches, or executes anything")
    func imagingSourcesHaveNoSideEffectAPIs() throws {
        let imaging = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Imaging")
        let files = try FileManager.default.contentsOfDirectory(at: imaging, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 3)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let relativePath = "Sources/Imaging/\(file.lastPathComponent)"
            #expect(
                ForbiddenAPIScan.findings(in: source, relativePath: relativePath).isEmpty,
                "\(file.lastPathComponent): \(ForbiddenAPIScan.findings(in: source, relativePath: relativePath))")
        }
        // Failing control: the scan must catch each planted call, or a clean result means nothing.
        let planted = [
            "NSWorkspace.shared.open(url)", "URLSession.shared.data(from: url)", "openURL(url)",
            "let p = Process()", "try Process.run(tool, arguments: [])", "NSAppleScript(source: s)",
            "UIApplication.shared.open(url)", "LSOpenCFURLRef(url, nil)",
            "posix_spawn(&pid, path, nil, nil, argv, nil)",
            "import AppKit", "WKWebView(frame: .zero)", "NSURLConnection(request: r, delegate: nil)",
            #"let u = "https://example.invalid"; NSWorkspace.shared.open(u)"#,
        ]
        for snippet in planted {
            #expect(!ForbiddenAPIScan.findings(in: "func f() {\n    \(snippet)\n}").isEmpty, "scan missed \(snippet)")
        }
        let fontImports = "import class AppKit.NSFont\nimport class AppKit.NSFontDescriptor"
        let fontPath = "Sources/Imaging/TextLayout.swift"
        #expect(ForbiddenAPIScan.findings(in: fontImports, relativePath: fontPath).isEmpty)
        #expect(!ForbiddenAPIScan.findings(in: fontImports).isEmpty)
        for wrongPath in [
            "TextLayout.swift", "Sources/Imaging/Other.swift", "Other/Sources/Imaging/TextLayout.swift",
            "Sources/Imaging/TextLayout.swift.bak", "./Sources/Imaging/TextLayout.swift",
        ] {
            #expect(!ForbiddenAPIScan.findings(in: fontImports, relativePath: wrongPath).isEmpty)
        }
        for rejected in [
            "import AppKit", "import class AppKit.NSWorkspace", "import class AppKit.NSFontManager",
            "import class AppKit.NSTextView", "import struct AppKit.NSFont", "import class AppKit.NSFont.Other",
            "@preconcurrency import class AppKit.NSFont", "import class AppKit.NSFont; import AppKit",
            "import class AppKit.NSFont; NSWorkspace.shared.open(url)", "import class\nAppKit.NSFont",
            "import /* gap */ class AppKit.NSFont", fontImports + "\nNSWorkspace.shared.open(url)",
            "import class AppKit.NSFont // approved?", " import class AppKit.NSFont",
            "import class AppKit.NSFont\nimport class AppKit.NSFont", "importclass AppKit.NSFont",
            "// AppKit", "let value = AppKit.NSFontManager.shared",
        ] {
            #expect(!ForbiddenAPIScan.findings(in: rejected, relativePath: fontPath).isEmpty, "missed \(rejected)")
        }
        #expect(
            ForbiddenAPIScan.findings(
                in: "// Process the image; never NSWorkspace here\nlet info = ProcessInfo.processInfo"
            ).isEmpty)
    }
}

/// Token scan over code with line comments stripped.
enum ForbiddenAPIScan {
    static let patterns = [
        #"\bNSWorkspace\b"#, #"\bURLSession\b"#, #"\bNSURLConnection\b"#, #"\bopenURL\b"#, #"\bUIApplication\b"#,
        #"\bProcess\s*\("#, #"\bProcess\.(run|launchedProcess)\b"#, #"\bNSTask\b"#, #"\bNSAppleScript\b"#,
        #"\bLSOpen\w*"#, #"\bposix_spawn\w*"#, #"\bsystem\s*\("#, #"\bimport\s+(AppKit|WebKit|SafariServices)\b"#,
        #"\bWKWebView\b"#, #"\bNetwork\.\b|\bimport\s+Network\b"#,
    ]

    /// An accidental-regression guard, not a sandbox or a proof against deliberate evasion.
    static func findings(in source: String, relativePath: String? = nil) -> [String] {
        var permittedImports: Set<String> =
            relativePath == "Sources/Imaging/TextLayout.swift"
            ? ["import class AppKit.NSFont", "import class AppKit.NSFontDescriptor"] : []
        let remaining = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { permittedImports.remove(String($0)) == nil }
            .joined(separator: "\n")
        if remaining.range(of: #"\bAppKit\b"#, options: .regularExpression) != nil { return ["AppKit"] }
        let code = remaining.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let range = line.range(of: "//") else { return line }
                let prefix = line[..<range.lowerBound]
                return prefix.contains("\"") ? line : prefix
            }
            .joined(separator: "\n")
        return patterns.filter { code.range(of: $0, options: .regularExpression) != nil }
    }
}
