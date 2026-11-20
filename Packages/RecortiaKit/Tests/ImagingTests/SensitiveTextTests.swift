// The detection cases in `SensitiveTextEmailTests`, `SensitiveTextPhoneTests` and
// `SensitiveTextMixedTests` are ported from Fosco by Gabriel Buzzi (MIT License),
// Tests/FoscoCoreTests/TextDetectorTests.swift at commit cf6ca8d4f176a5c6628a6ccfdb2c2db0abaa5ba8.
// The license text is in Sources/Imaging/SensitiveText.swift.

import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

/// Text of every match, in order, as "kind:text".
private func detect(_ text: String) throws -> [String] {
    try SensitiveTextMatcher.shared.get().matches(in: text).map { "\($0.kind.rawValue):\(text[$0.range])" }
}

@Suite("SensitiveText: patterns compile")
struct SensitiveTextPatternTests {
    @Test("Every built-in pattern compiles, and the shared matcher is available")
    func everyPatternCompiles() throws {
        for pattern in SensitiveTextMatcher.patterns {
            #expect(throws: Never.self, "pattern \(pattern.name)") {
                _ = try NSRegularExpression(pattern: pattern.source, options: [.caseInsensitive])
            }
        }
        _ = try SensitiveTextMatcher.shared.get()
        _ = try DataDetectorMatcher()
    }
}

@Suite("SensitiveText: e-mail addresses (Fosco cases)")
struct SensitiveTextEmailTests {
    @Test(arguments: [
        ("Contato: maria.silva@exemplo.com.br", "maria.silva@exemplo.com.br"),
        ("fulano_exemplo+teste@gmail.com", "fulano_exemplo+teste@gmail.com"),
        ("<ANA@EXEMPLO.COM>,", "ANA@EXEMPLO.COM"),
        ("mailto:felipe@exemplo.adv.br.", "felipe@exemplo.adv.br"),
        ("\"email\": \"ana.clara@exemplo.io\",", "ana.clara@exemplo.io"),
        ("jp.alves@exemplo.tech", "jp.alves@exemplo.tech"),
    ])
    func findsPlainAddresses(text: String, expected: String) throws {
        #expect(try detect(text) == ["email:\(expected)"])
    }

    @Test func findsSeveralAddressesOnOneLine() throws {
        #expect(
            try detect("ana.beatriz.souza@exemplo.io, carlos@exemplo.dev") == [
                "email:ana.beatriz.souza@exemplo.io", "email:carlos@exemplo.dev",
            ])
    }

    @Test(arguments: [
        ("ana.beatriz. souza@exemplo.io", "ana.beatriz. souza@exemplo.io"),
        ("exemplo@gmail. com", "exemplo@gmail. com"),
        ("rafa@exemplo.com. br", "rafa@exemplo.com. br"),
        ("Bruno Limabruno.lima@exemplo.com.br", "Limabruno.lima@exemplo.com.br"),
        ("anadgmail.com", "anadgmail.com"),
        ("sofiaQhotmail.com.br", "sofiaQhotmail.com.br"),
        ("\"email\": \"ana.clara@exemplo-io\",", "ana.clara@exemplo-io"),
        ("ana.clara@exemplo.1o", "ana.clara@exemplo.1o"),
        ("exemplo@gmail,corn", "exemplo@gmail,corn"),
        ("rafa@exemplo.c0m", "rafa@exemplo.c0m"),
    ])
    func toleratesOCRDamage(text: String, expected: String) throws {
        #expect(try detect(text) == ["email:\(expected)"])
    }

    @Test(arguments: [
        ("fulano.si…@gmail.com", "fulano.si…@gmail.com"),
        ("fulano.si...@gmail.com", "fulano.si...@gmail.com"),
        ("fulano.silva@gm…", "fulano.silva@gm…"),
        ("fulano.silva@gmail.c...", "fulano.silva@gmail.c..."),
    ])
    func findsAddressesTruncatedByTheUI(text: String, expected: String) throws {
        #expect(try detect(text) == ["email:\(expected)"])
    }

    @Test func stopsAtTheEndOfTheSentence() throws {
        #expect(try detect("Escreva para ana@exemplo.com. Me liga depois.") == ["email:ana@exemplo.com"])
        #expect(try detect("Escreva para ana@exemplo.com. Depois falamos.") == ["email:ana@exemplo.com"])
    }

    @Test(arguments: [
        "SEGUE @FULANODETAL",
        "Segue @fulano.detal no Instagram",
        "@Injectable() export class Foo",
        "npm i react@18.2.0 next@canary @types/node",
        "fulano@MacBook-Pro ~ %",
        "git clone git@github.com:org/repo.git",
        "https://mail.google.com/mail/u/0",
        "www.gmail.com e outlook.live.com",
        "preço @ R$ 10,00",
        "ssh deploy@api-dev e root@web-app-01",
        "pnpm add typescript@5.4.0-dev eslint@9.0.0-rc.1",
        "docker pull app@sha256-9f86d081884c",
    ])
    func ignoresThingsThatOnlyLookLikeAddresses(text: String) throws {
        #expect(try detect(text).isEmpty)
    }
}

@Suite("SensitiveText: phone numbers (Fosco cases)")
struct SensitiveTextPhoneTests {
    @Test(arguments: [
        "(11) 90765-4321", "11 90765-4321", "11907654321", "(11)90765-4321", "1190765-4321",
        "+55 11 90765-4321", "+5511907654321", "5511907654321", "+55 (31) 9 0765-4321",
        "47 9 0123-4567", "(47) 4004-5566", "31 4004-7788", "1140045566", "(011) 90765-4321",
        "90765-4321", "11 90765–4321", "11.90765.4321",
    ])
    func findsBrazilianNumbers(number: String) throws {
        #expect(try detect(number) == ["phone:\(number)"])
        #expect(try detect("Telefone: \(number), ok?") == ["phone:\(number)"])
    }

    @Test(arguments: [
        "+1 (415) 555-0132", "+1 415-555-0199", "415-555-0199", "(415) 555-0132", "415.555.0199",
        "+351 912 345 678", "+44 20 7946 0958", "+33 1 23 45 67 89", "+54 9 11 1234-5678", "+491512345678",
    ])
    func findsForeignNumbers(number: String) throws {
        #expect(try detect(number) == ["phone:\(number)"])
    }

    @Test func doesNotSwallowTheNextColumn() throws {
        #expect(try detect("+44 20 7946 0958 2026-1126 27/11/2026 16:54") == ["phone:+44 20 7946 0958"])
        #expect(try detect("+55 21 90701-3344 2026-1014 07/11/2026 10:26") == ["phone:+55 21 90701-3344"])
        #expect(try detect("(47) 4004-5566 2026-1035 16/11/2026 13:05 R$ 2.251,65") == ["phone:(47) 4004-5566"])
    }

    @Test func findsSeveralNumbersOnOneLine() throws {
        #expect(try detect("5511907654321  +5511902345678") == ["phone:5511907654321", "phone:+5511902345678"])
        #expect(
            try detect("Fixo (21) 4004-5566 / Cel (21) 90876-5432") == [
                "phone:(21) 4004-5566", "phone:(21) 90876-5432",
            ])
    }

    @Test(arguments: [
        "Pedido #1234567890 em 19/11/2026 10:30 - R$ 1.299,90",
        "\"id\": 4815162342, \"created_at\": 1795093188,",
        "1795093188593",
        "CNPJ 12.345.678/0001-90 · CPF 529.982.247-25",
        "192.168.0.12 · v4.18.2 · 2026.11.000482",
        "2026-11-19T14:32:10Z",
        "CEP 01310-100 · Rua das Flores, 1200",
        "R$ 128.480,90 · 1.284 · +12,5% · UTC+03:00",
        "0800 123 4567",
        "#11907654321",
        "2026-1000 01/11/2026 08:00 R$ 189,90",
        "4111 1111 1111 1111",
    ])
    func ignoresOtherNumbers(text: String) throws {
        #expect(try detect(text).isEmpty)
    }
}

@Suite("SensitiveText: mixed lines (Fosco cases)")
struct SensitiveTextMixedTests {
    @Test func findsBothKindsOnATableRow() throws {
        #expect(
            try detect("Bruno Lima bruno.lima@exemplo.com.br (47) 9 0888-7777 Inativo") == [
                "email:bruno.lima@exemplo.com.br", "phone:(47) 9 0888-7777",
            ])
    }

    @Test func reportsANumberInsideAnAddressOnce() throws {
        #expect(try detect("11907654321@exemplo.com") == ["email:11907654321@exemplo.com"])
    }

    @Test func honoursTheRequestedKinds() throws {
        let text = "ana@exemplo.com 11 90765-4321"
        let matcher = try SensitiveTextMatcher.shared.get()
        #expect(matcher.matches(in: text, kinds: [.phone]).map(\.kind) == [.phone])
        #expect(matcher.matches(in: text, kinds: []).isEmpty)
    }
}

@Suite("SensitiveText: look-alikes that must not be masked")
struct SensitiveTextNegativeTests {
    @Test(arguments: [
        "git@github.com:org/repo.git",
        "Version 1.2.3.4 (build 8812)",
        "Released 2026-11-19 · due 19/11/2026",
        "Meeting at 14:32:10 or 09:05",
        "Ticket #12345678901 reopened",
        "Total R$ 1.234,56 (R$ 12.345,67 em 3x)",
        "Servers 10.0.0.1, 192.168.100.200 and 172.16.254.1",
        "550e8400-e29b-41d4-a716-446655440000",
        "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "Accent #1E90FF on #FFFFFF, border #333",
        "Build 2026.11.19.1432 · commit 9f86d081884c",
    ])
    func ignoresLookAlikes(text: String) throws {
        #expect(try detect(text).isEmpty)
    }
}

@Suite("SensitiveText: tiles and boxes")
struct SensitiveTextGeometryTests {
    @Test(
        "Fine and coarse tiles cover every pixel and stay within the tile budget",
        arguments: [(1200, 800, 1.0), (2400, 1600, 2.0), (3024, 1964, 2.0), (2560, 1440, 1.0), (5120, 2880, 2.0)])
    func tilesCoverTheImage(width: Int, height: Int, pixelsPerPoint: Double) {
        let size = CGSize(width: width, height: height)
        for layout in TileLayout.standard(pixelsPerPoint: pixelsPerPoint) {
            let tiles = tileRects(for: size, layout: layout)
            for tile in tiles {
                #expect(tile.width * layout.scale <= layout.tileSide + 2)
                #expect(tile.height * layout.scale <= layout.tileSide + 2)
            }
            // Every pixel centre is inside some tile.
            let union = tiles.reduce(CGRect.null) { $0.union($1) }
            #expect(union.minX <= 0 && union.minY <= 0 && union.maxX >= size.width && union.maxY >= size.height)
            for x in stride(from: 0.5, to: size.width, by: 97) {
                for y in stride(from: 0.5, to: size.height, by: 89) {
                    #expect(tiles.contains { $0.contains(CGPoint(x: x, y: y)) }, "uncovered \(x),\(y)")
                }
            }
        }
    }

    @Test("Boxes grow, round outward to whole pixels and clamp to the image")
    func outsetRoundsOutwardAndClamps() throws {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 50)
        let inside = try #require(
            SensitiveTextScanner.outset((.email, CGRect(x: 10.4, y: 20.6, width: 30.2, height: 10)), within: bounds))
        #expect(inside.rect == Rect(x: 8, y: 18, width: 35, height: 15))
        let edge = try #require(
            SensitiveTextScanner.outset((.phone, CGRect(x: -3, y: 45, width: 20, height: 8)), within: bounds))
        #expect(edge.rect == Rect(x: 0, y: 43, width: 19, height: 7))
        #expect(SensitiveTextScanner.outset((.phone, CGRect(x: 200, y: 0, width: 5, height: 5)), within: bounds) == nil)
    }

    @Test("Duplicates from overlapping tiles merge into one region")
    func duplicatesMerge() {
        let merged = SensitiveTextScanner.mergeRegions([
            (.email, CGRect(x: 10, y: 10, width: 100, height: 12)),
            (.email, CGRect(x: 12, y: 11, width: 98, height: 12)),
            (.phone, CGRect(x: 300, y: 10, width: 80, height: 12)),
        ])
        #expect(merged.count == 2)
    }
}

@Suite("SensitiveText: sweep on a synthetic screen")
struct SensitiveTextSweepTests {
    @Test("The pattern sweep covers planted items on a small screen", VisionRuntime.required)
    func sweepCoversPlantedItems() async throws {
        let screen = try SensitiveScreen.render(
            widthPoints: 600, heightPoints: 160, scale: 2, pointSize: 14, theme: .light, language: .portugueseBrazil,
            layout: .singleColumn)
        let regions = try await SensitiveTextScanner().sensitiveRegions(
            in: screen.image, pixelsPerPoint: 2,
            languages: [OCRRecognitionTests.portuguese, OCRRecognitionTests.english])
        #expect(!screen.planted.isEmpty)
        for item in screen.planted {
            #expect(
                regions.contains { region in
                    let r = region.rect
                    return r.minX <= item.rect.minX && r.minY <= item.rect.minY && r.maxX >= item.rect.maxX
                        && r.maxY >= item.rect.maxY
                },
                "\(item.text) at \(item.rect) not covered; regions \(regions.map { [$0.rect.minX, $0.rect.minY, $0.rect.maxX, $0.rect.maxY] })"
            )
        }
    }

    @Test("A cancelled sweep throws CancellationError", VisionRuntime.required)
    func sweepHonoursCancellation() async throws {
        let screen = try SensitiveScreen.render(
            widthPoints: 1512, heightPoints: 982, scale: 2, pointSize: 12, theme: .dark, language: .english,
            layout: .denseColumns)
        let task = Task {
            try await SensitiveTextScanner().sensitiveRegions(
                in: screen.image, pixelsPerPoint: 2, languages: [OCRRecognitionTests.english])
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

@Suite("SensitiveText: review findings (2026-11-19)")
struct SensitiveTextReviewTests {
    @Test(
        "R02: an international number keeps every digit up to E.164's fifteen",
        arguments: ["+44 20 7946 09 58", "+49 30 1234 5678 90", "+86 10 5555 0123 456"])
    func internationalNumberIsComplete(number: String) throws {
        #expect(try detect(number) == ["phone:\(number)"])
        #expect(try detect("Tel. \(number) 2026-1126") == ["phone:\(number)"])
    }

    @Test("R06: only SSH remote syntax suppresses a git@ address")
    func gitMailboxIsAnAddress() throws {
        #expect(try detect("git@example.com") == ["email:git@example.com"])
        #expect(try detect("Write to git@example.org: we reply") == ["email:git@example.org"])
        #expect(try detect("git clone git@example.com:owner/repo.git").isEmpty)
    }

    @Test(
        "R07: apostrophes and accented letters belong to the local part",
        arguments: ["o'brien@example.com", "d’avila@example.org", "joão.ninguém@exemplo.com.br"])
    func localPartPunctuation(address: String) throws {
        #expect(try detect("Contato: \(address)") == ["email:\(address)"])
    }

    @Test(
        "R08: compact and area-code-less numbers after a phone label",
        arguments: [
            ("Phone: 5551234567", "5551234567"), ("Call 2025550100", "2025550100"),
            ("Celular: 987654321", "987654321"), ("Tel 4004-5566", "4004-5566"),
            ("Fone: 9 8765-4321", "9 8765-4321"), ("WhatsApp 98765-4321", "98765-4321"),
        ])
    func labelledCompactNumbers(text: String, number: String) throws {
        #expect(try detect(text) == ["phone:\(number)"])
    }

    @Test(
        "R08: area-code-less mobile numbers are found when formatted, without a label",
        arguments: ["9 8765-4321", "98765-4321"])
    func formattedLocalMobile(number: String) throws {
        #expect(try detect("ok \(number) ok") == ["phone:\(number)"])
    }

    @Test(
        "R08: bare digit runs stay unmasked without a phone label",
        arguments: [
            "2025550100", "id 4815162342", "Pedido 1034567890", "ref 987654321", "2026-1126", "Hotel 2025550100",
            "4111111111111111", "Phone: 1034567890",
        ])
    func bareDigitRunsAreNotPhones(text: String) throws {
        #expect(try detect(text).isEmpty)
    }

    @Test(
        "R13: pathological 64 KB lines finish within a second",
        arguments: [
            String(repeating: "a", count: 65_536), String(repeating: "a.", count: 32_768),
            "a@" + String(repeating: "a.", count: 32_767), String(repeating: "a@a", count: 21_845),
            "+" + String(repeating: "1 ", count: 32_767), String(repeating: "9-", count: 32_768),
            String(repeating: "a. ", count: 21_845), String(repeating: "x@a-", count: 16_384),
        ])
    func pathologicalLinesAreBounded(text: String) throws {
        let matcher = try SensitiveTextMatcher.shared.get()
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = matcher.matches(in: text) }
        #expect(elapsed < .seconds(1), "took \(elapsed) on \(text.prefix(12))…")
    }

    @Test("R13: an address past the length bound is still found whole")
    func addressDeepInALongLineIsFound() throws {
        let filler = String(repeating: "lorem ipsum ", count: 1_000)
        #expect(try detect(filler + "ana@example.com " + filler) == ["email:ana@example.com"])
    }
}
