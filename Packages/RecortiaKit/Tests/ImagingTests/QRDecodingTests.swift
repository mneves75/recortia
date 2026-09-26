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

    @Test("Malformed codes yield no payload")
    func malformed() async throws {
        let malformed = try QRFixture.all().filter(\.isMalformed)
        #expect(malformed.count >= 2)
        for fixture in malformed {
            #expect(try await decoder.decode(fixture.image).isEmpty, "\(fixture.name)")
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

    @Test("Bitstream parser recovers message bytes from Vision's raw data codewords")
    func bitstreamParser() {
        // Captured from Vision's BarcodeObservation.payloadData for CIQRCodeGenerator codes (level M).
        let cases: [(String, Data)] = [
            ("40b68656c6c6f20776f726c640ec11ec", Data("hello world".utf8)),
            ("1030003240a35000ec11ec11ec11ec11", Data("000201010212".utf8)),
            ("2045b256bf63e9a07b2ba1daa1d2ba8209da81d383b9d9d800ec11ec", Data("WIFI:S:Net;T:WPA;P:pw;;".utf8)),
            ("40a4f6cc3a120c3a7c3a36f0ec11ec11", Data("Olá ção".utf8)),
            ("405fffe0080410ec11ec11ec11ec11ec", Data([0xFF, 0xFE, 0x00, 0x80, 0x41])),
        ]
        for (raw, expected) in cases {
            #expect(
                QRBitstream.messageBytes(fromDataCodewords: Self.hex(raw), expectedString: nil) == expected, "\(raw)")
        }
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
            #expect(
                ForbiddenAPIScan.findings(in: source).isEmpty,
                "\(file.lastPathComponent): \(ForbiddenAPIScan.findings(in: source))")
        }
        // Failing control: the scan must catch each planted call, or a clean result means nothing.
        let planted = [
            "NSWorkspace.shared.open(url)", "URLSession.shared.data(from: url)", "openURL(url)",
            "let p = Process()", "try Process.run(tool, arguments: [])", "NSAppleScript(source: s)",
            "UIApplication.shared.open(url)", "LSOpenCFURLRef(url, nil)",
            "posix_spawn(&pid, path, nil, nil, argv, nil)",
            "import AppKit", "WKWebView(frame: .zero)", "NSURLConnection(request: r, delegate: nil)",
        ]
        for snippet in planted {
            #expect(!ForbiddenAPIScan.findings(in: "func f() {\n    \(snippet)\n}").isEmpty, "scan missed \(snippet)")
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

    static func findings(in source: String) -> [String] {
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let range = line.range(of: "//") else { return line }
                return line[..<range.lowerBound]
            }
            .joined(separator: "\n")
        return patterns.filter { code.range(of: $0, options: .regularExpression) != nil }
    }
}
