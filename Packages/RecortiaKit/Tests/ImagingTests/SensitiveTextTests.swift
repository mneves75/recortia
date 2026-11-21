// The detection cases in `SensitiveTextEmailTests`, `SensitiveTextPhoneTests` and
// `SensitiveTextMixedTests` are ported from Fosco by Gabriel Buzzi (MIT License),
// Tests/FoscoCoreTests/TextDetectorTests.swift at commit cf6ca8d4f176a5c6628a6ccfdb2c2db0abaa5ba8.
// The license text is in Sources/Imaging/SensitiveText.swift.

import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Synchronization
import Testing

@testable import Imaging

/// Text of every match, in order, as "kind:text".
private func detect(_ text: String) throws -> [String] {
    try SensitiveTextMatcher.shared.get().matches(in: text).map {
        "\($0.kind.rawValue):\((text as NSString).substring(with: $0.range))"
    }
}

@Suite("SensitiveText: patterns compile")
struct SensitiveTextPatternTests {
    @Test("Every built-in pattern compiles, and the shared matcher is available")
    func everyPatternCompiles() throws {
        for pattern in SensitiveTextMatcher.patterns + SensitiveTextMatcher.overlongRunPatterns {
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
        // The whole whitespace-free token is covered (W1), punctuation included.
        ("<ANA@EXEMPLO.COM>,", "<ANA@EXEMPLO.COM>,"),
        ("mailto:felipe@exemplo.adv.br.", "mailto:felipe@exemplo.adv.br."),
        ("\"email\": \"ana.clara@exemplo.io\",", "\"ana.clara@exemplo.io\","),
        ("jp.alves@exemplo.tech", "jp.alves@exemplo.tech"),
    ])
    func findsPlainAddresses(text: String, expected: String) throws {
        #expect(try detect(text) == ["email:\(expected)"])
    }

    @Test func findsSeveralAddressesOnOneLine() throws {
        #expect(
            try detect("ana.beatriz.souza@exemplo.io, carlos@exemplo.dev") == [
                "email:ana.beatriz.souza@exemplo.io,", "email:carlos@exemplo.dev",
            ])
    }

    @Test(arguments: [
        ("ana.beatriz. souza@exemplo.io", "ana.beatriz. souza@exemplo.io"),
        ("exemplo@gmail. com", "exemplo@gmail. com"),
        ("rafa@exemplo.com. br", "rafa@exemplo.com. br"),
        ("Bruno Limabruno.lima@exemplo.com.br", "Limabruno.lima@exemplo.com.br"),
        ("anadgmail.com", "anadgmail.com"),
        ("sofiaQhotmail.com.br", "sofiaQhotmail.com.br"),
        ("\"email\": \"ana.clara@exemplo-io\",", "\"ana.clara@exemplo-io\","),
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
        #expect(try detect("Escreva para ana@exemplo.com. Me liga depois.") == ["email:ana@exemplo.com."])
        #expect(try detect("Escreva para ana@exemplo.com. Depois falamos.") == ["email:ana@exemplo.com."])
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

    /// Fosco stopped at the number; whole-token coverage (W1) takes adjacent digit groups joined by
    /// one separator, so the next numeric column is masked too, up to the "/" of the date.
    @Test func coversTheAdjacentDigitGroups() throws {
        #expect(try detect("+44 20 7946 0958 2026-1126 27/11/2026 16:54") == ["phone:+44 20 7946 0958 2026-1126 27"])
        #expect(try detect("+55 21 90701-3344 2026-1014 07/11/2026 10:26") == ["phone:+55 21 90701-3344 2026-1014 07"])
        #expect(
            try detect("(47) 4004-5566 2026-1035 16/11/2026 13:05 R$ 2.251,65") == ["phone:(47) 4004-5566 2026-1035 16"]
        )
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

    @Test("Boxes grow, round outward to whole pixels and clamp to the image (outside: R05)")
    func outsetRoundsOutwardAndClamps() throws {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 50)
        let inside = try SensitiveTextScanner.outset(
            (.email, CGRect(x: 10.4, y: 20.6, width: 30.2, height: 10)), within: bounds)
        #expect(inside.rect == Rect(x: 8, y: 18, width: 35, height: 15))
        let edge = try SensitiveTextScanner.outset((.phone, CGRect(x: -3, y: 45, width: 20, height: 8)), within: bounds)
        #expect(edge.rect == Rect(x: 0, y: 43, width: 19, height: 7))
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

    @Test("The store entry point sweeps the stored pixels, and fails when the asset is gone", VisionRuntime.required)
    func storeEntryPoint() async throws {
        let screen = try SensitiveScreen.render(
            widthPoints: 600, heightPoints: 160, scale: 2, pointSize: 14, theme: .light, language: .english,
            layout: .singleColumn)
        let store = ImageStore()
        let info = await store.insert(try ImageDecoder.canonicalize(screen.image), origin: .imported)
        let languages = [OCRRecognitionTests.english, OCRRecognitionTests.portuguese]
        let direct = try await SensitiveTextScanner().sensitiveRegions(
            in: screen.image, pixelsPerPoint: 2, languages: languages)
        let stored = try await SensitiveTextScanner().sensitiveRegions(
            of: info.id, in: store, pixelsPerPoint: 2, languages: languages)
        #expect(!stored.isEmpty && stored == direct)
        await store.remove(info.id)
        await #expect(throws: SensitiveTextError.assetUnavailable) {
            _ = try await SensitiveTextScanner().sensitiveRegions(
                of: info.id, in: store, pixelsPerPoint: 2, languages: languages)
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

    @Test(
        "A sweep cancelled while its first tiles run starts no further tile and drops its result",
        VisionRuntime.required)
    func sweepCancelledMidway() async throws {
        let screen = try SensitiveScreen.render(
            widthPoints: 1512, heightPoints: 982, scale: 2, pointSize: 12, theme: .dark, language: .english,
            layout: .denseColumns)
        let jobs = try SensitiveTextScanner.tileJobs(
            for: CGSize(width: screen.image.width, height: screen.image.height), pixelsPerPoint: 2, fineTileSide: 1024)
        try #require(jobs.count > 2 * SensitiveTextScanner.concurrentTiles, "\(jobs.count) tiles")
        let started = TileCounter()
        let (firstTile, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await SensitiveTextScanner().sensitiveRegions(
                in: screen.image, pixelsPerPoint: 2, languages: [OCRRecognitionTests.english],
                tileStarted: {
                    started.count.add(1, ordering: .relaxed)
                    signal.yield()
                })
        }
        var tiles = firstTile.makeAsyncIterator()
        _ = await tiles.next()
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        let startedBeforeCancel = started.count.load(ordering: .relaxed)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let elapsed = clock.now - cancelledAt
        // At most `concurrentTiles` were queued but not yet running when the cancellation arrived;
        // nothing after it starts, so the sweep never reaches its end.
        let total = started.count.load(ordering: .relaxed)
        #expect(total <= startedBeforeCancel + SensitiveTextScanner.concurrentTiles, "\(total) tiles started")
        #expect(total < jobs.count, "\(total) of \(jobs.count) tiles started")
        #expect(elapsed < .seconds(10), "ended \(elapsed) after cancellation")
    }

    @Test("Once the sweep is cancelled no tile starts, even when the running tiles return normally")
    func cancelledSchedulerStartsNoTile() async throws {
        let started = TileCounter()
        let concurrency = 3
        let task = Task {
            try await SensitiveTextScanner.scanTiles(Array(0..<20), concurrency: concurrency) { job in
                started.count.add(1, ordering: .relaxed)
                // The first tiles run until cancelled and then return without throwing, as a
                // recognizer that ignores cancellation would.
                while job < concurrency, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
                return []
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while started.count.load(ordering: .relaxed) < concurrency, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(started.count.load(ordering: .relaxed) == concurrency)
        task.cancel()
        _ = try? await task.value
        #expect(started.count.load(ordering: .relaxed) == concurrency, "a tile started after the cancellation")
    }
}

private final class TileCounter: Sendable {
    let count = Atomic<Int>(0)
}

@Suite("SensitiveText: review findings (2026-11-19)")
struct SensitiveTextReviewTests {
    @Test(
        "R02: an international number keeps every digit up to E.164's fifteen",
        arguments: ["+44 20 7946 09 58", "+49 30 1234 5678 90", "+86 10 5555 0123 456"])
    func internationalNumberIsComplete(number: String) throws {
        #expect(try detect(number) == ["phone:\(number)"])
        #expect(try detect("Tel. \(number) 2026-1126") == ["phone:\(number) 2026-1126"])
        #expect(try detect("Tel. \(number), 2026-1126") == ["phone:\(number)"])
    }

    @Test("R06: only SSH remote syntax suppresses a git@ address")
    func gitMailboxIsAnAddress() throws {
        #expect(try detect("git@example.com") == ["email:git@example.com"])
        #expect(try detect("Write to git@example.org: we reply") == ["email:git@example.org:"])
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

@Suite("SensitiveText: sweep review findings (2026-11-19)")
struct SensitiveTextSweepReviewTests {
    private let bounds = CGRect(x: 0, y: 0, width: 100, height: 50)

    @Test(
        "R04: a split next to @, a dot or a hyphen is also read without the inserted space",
        arguments: [
            [("ana@acme", false), (".com.br", false)], [("ana", false), ("@example.com", false)],
            [("ana@", false), ("example.org", false)], [("90765", false), ("-4321", false)],
        ])
    func fragmentReadingsRejoinSplitItems(parts: [(String, Bool)]) throws {
        let matcher = try SensitiveTextMatcher.shared.get()
        let whole = parts.map(\.0).joined()
        let readings = fragmentReadings(parts.map { (text: $0.0, isGlued: $0.1) })
        #expect(
            readings.contains { line in
                matcher.matches(in: line.text).contains { (line.text as NSString).substring(with: $0.range) == whole }
            })
        #expect(readings.first?.text == joinFragments(parts.map { (text: $0.0, isGlued: $0.1) }).text)
    }

    @Test("R05: a match that cannot be mapped onto the image fails the sweep")
    func unmappableMatchFailsClosed() {
        #expect(throws: SensitiveTextError.regionOutsideImage) {
            _ = try SensitiveTextScanner.finalRegions(
                [(.phone, CGRect(x: 200, y: 0, width: 5, height: 5))], within: bounds)
        }
        #expect(throws: SensitiveTextError.regionOutsideImage) {
            _ = try SensitiveTextScanner.finalRegions(
                [
                    (.email, CGRect(x: 10, y: 10, width: 20, height: 10)),
                    (.email, CGRect(x: CGFloat.nan, y: 0, width: 5, height: 5)),
                ],
                within: bounds)
        }
    }

    @Test("R09: cancellation that arrives during the final merge is reported")
    func cancellationDuringMergeThrows() async {
        let found: [SensitiveTextScanner.BoxedMatch] = [(.email, CGRect(x: 10, y: 10, width: 20, height: 10))]
        let bounds = self.bounds
        // Cancelled after finalization's entry check, as if during the merge.
        let task = Task {
            try SensitiveTextScanner.finalRegions(
                found, within: bounds, afterEntryCheck: { withUnsafeCurrentTask { $0?.cancel() } })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("R12: tile and match budgets fail the sweep with a typed error")
    func budgetsFailClosed() throws {
        #expect(throws: SensitiveTextError.tooManyTiles) {
            _ = try SensitiveTextScanner.tileJobs(
                for: CGSize(width: 20_000, height: 20_000), pixelsPerPoint: 1, fineTileSide: 1024)
        }
        let admitted = try SensitiveTextScanner.tileJobs(
            for: CGSize(width: 8_000, height: 5_000), pixelsPerPoint: 1, fineTileSide: 1024)
        #expect(admitted.count <= SensitiveTextScanner.maximumTiles)
        let many = (0...SensitiveTextScanner.maximumMatches).map { index in
            (
                kind: SensitiveTextKind.phone,
                rect: CGRect(x: Double(index % 90), y: Double(index / 90), width: 1, height: 1)
            )
        }
        #expect(throws: SensitiveTextError.tooManyMatches) {
            _ = try SensitiveTextScanner.finalRegions(many, within: CGRect(x: 0, y: 0, width: 100, height: 100))
        }
    }

    @Test("R17: the merged mask list does not depend on the order tiles finish")
    func mergeIsOrderIndependent() {
        let a: SensitiveTextScanner.BoxedMatch = (.email, CGRect(x: 0, y: 0, width: 20, height: 10))
        let b: SensitiveTextScanner.BoxedMatch = (.phone, CGRect(x: 18, y: 0, width: 4, height: 10))
        let c: SensitiveTextScanner.BoxedMatch = (.phone, CGRect(x: 20, y: 0, width: 8, height: 10))
        let orders = [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]]
        let results = orders.map { order in
            SensitiveTextScanner.mergeRegions(order).map { "\($0.kind.rawValue) \($0.rect)" }
        }
        #expect(Set(results.map { $0.joined(separator: "; ") }).count == 1, "\(results)")
    }
}

@Suite("SensitiveText: security review findings (2026-11-19)")
struct SensitiveTextSecurityReviewTests {
    /// 130 local-part letters outside the BMP (two UTF-16 units each), apostrophes included.
    private static let longLocalPart: String = {
        let letter = "\u{1D4B6}"
        return String(repeating: letter, count: 64) + "'" + String(repeating: letter, count: 32) + "'"
            + String(repeating: letter, count: 32)
    }()

    @Test(
        "A letter run longer than a local part glued to an address still masks the address",
        arguments: [
            String(repeating: "漢字", count: 50), String(repeating: "x", count: 100),
            String(repeating: "สวัสดีครับ", count: 10),
        ])
    func gluedRunBeforeAnAddress(prefix: String) throws {
        let text = "Contato: " + prefix + "ana@example.com fim"
        let matches = try SensitiveTextMatcher.shared.get().matches(in: text)
        let source = text as NSString
        try #require(matches.count == 1, "\(matches.map { source.substring(with: $0.range) })")
        let masked = source.substring(with: matches[0].range)
        #expect(matches[0].kind == .email)
        // The whole glued token is covered (W1), not only the last 64 characters of the local part.
        #expect(masked == prefix + "ana@example.com")
    }

    @Test("The window overlap exceeds every pattern's longest match, and the bound is not loose")
    func windowOverlapCoversTheLongestMatch() {
        #expect(SensitiveTextMatcher.longestMatchUTF16 < SensitiveTextMatcher.windowOverlap)
        #expect(SensitiveTextMatcher.patterns.allSatisfy { $0.maximumUTF16Length > 0 })
        let domain =
            String(repeating: String(repeating: "a", count: 63) + ".", count: 8) + String(repeating: "a", count: 24)
        let address = Self.longLocalPart + ". " + Self.longLocalPart + "@" + domain
        #expect(address.utf16.count <= SensitiveTextMatcher.longestMatchUTF16)
        #expect(address.utf16.count + 16 >= SensitiveTextMatcher.longestMatchUTF16)
    }

    @Test("A maximum-length non-BMP address across a window seam is found once and whole")
    func longestAddressAcrossAWindowSeam() throws {
        let domain =
            String(repeating: String(repeating: "a", count: 63) + ".", count: 8) + String(repeating: "a", count: 24)
        let address = Self.longLocalPart + ". " + Self.longLocalPart + "@" + domain
        #expect(address.utf16.count > 1024)
        // Start ten units before the second window, so the address crosses the first window's overlap.
        let start = SensitiveTextMatcher.windowLength - SensitiveTextMatcher.windowOverlap - 10
        let text = String(repeating: " ", count: start) + address + String(repeating: " ", count: 9_000)
        #expect(try detect(text) == ["email:\(address)"])
    }
}

@Suite("SensitiveText: tile seams (R03)")
struct SensitiveTextSeamTests {
    /// 512–1024 px of ink at 13 pt on a 2x capture: wider than a 1024 fine tile's 512 px overlap.
    static let localPart = "firstname.middlename.lastname.department.team.region"
    static let address = localPart + "@example.com"

    @Test(
        "An address wider than the fine overlap is masked once, inside a tile or across a seam",
        VisionRuntime.required, arguments: [false, true])
    func addressAcrossASeam(straddles: Bool) async throws {
        let (widthPoints, heightPoints, scale, pointSize) = (1200, 200, 2, 13.0)
        let size = CGSize(width: widthPoints * scale, height: heightPoints * scale)
        let probe = try SensitiveScreen.renderItem(
            Self.address, kind: .email, widthPoints: widthPoints, heightPoints: heightPoints, scale: scale,
            pointSize: pointSize, x: 0, top: 150)
        let ink = try #require(probe.planted.first).rect
        try #require((512...1024).contains(ink.width), "ink width \(ink.width)")
        let fine = try #require(TileLayout.standard(pixelsPerPoint: Double(scale), fineTileSide: 1024).first)
        let columns = tileRects(for: size, layout: fine).map { ($0.minX, $0.maxX) }
        func isInsideAFineTile(_ x: CGFloat) -> Bool {
            columns.contains { $0.0 <= x + ink.minX - 4 && x + ink.maxX + 4 <= $0.1 }
        }
        // Inside: near the left edge of the first tile. Across: the "@" just past the first tile's right
        // edge, so that tile sees only a local part, while the address starts well before the second
        // tile, which sees only its tail.
        let local = try #require(
            try SensitiveScreen.renderItem(
                Self.localPart, kind: .email, widthPoints: widthPoints, heightPoints: heightPoints, scale: scale,
                pointSize: pointSize, x: 0, top: 150
            ).planted.first
        ).rect
        let x = (straddles ? columns[0].1 + 30 - local.maxX : 40).rounded()
        if straddles { try #require(x + ink.minX < columns[1].0 - 40, "x \(x), tiles \(columns)") }
        try #require(isInsideAFineTile(x) != straddles, "x \(x), tiles \(columns)")
        let screen = try SensitiveScreen.renderItem(
            Self.address, kind: .email, widthPoints: widthPoints, heightPoints: heightPoints, scale: scale,
            pointSize: pointSize, x: x, top: 150)
        let item = try #require(screen.planted.first)
        let regions = try await SensitiveTextScanner(fineTileSide: 1024).sensitiveRegions(
            in: screen.image, pixelsPerPoint: Double(scale), languages: [OCRRecognitionTests.english])
        let covering = regions.map {
            CGRect(x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width, height: $0.rect.height)
        }.filter { $0.intersects(item.rect) }
        #expect(covering.count == 1, "x \(x): \(covering)")
        #expect(covering.contains { $0.contains(item.rect) }, "x \(x): \(item.rect) not covered by \(covering)")
    }
}

@Suite("SensitiveText: fixture ground truth (R11)")
struct SensitiveScreenGroundTruthTests {
    @Test("A planted rectangle is the bounding box of the pixels painted for it", arguments: [1, 2])
    func plantedRectMatchesPaintedInk(scale: Int) throws {
        let screen = try SensitiveScreen.renderItem(
            "ana.o'brien+news@example.org", kind: .email, widthPoints: 400, heightPoints: 60, scale: scale,
            pointSize: 13, x: 37, top: 21)
        let planted = try #require(screen.planted.first).rect
        let (width, height) = (screen.image.width, screen.image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(screen.image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        var ink = CGRect.null
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4] < 255 {
                ink = ink.union(CGRect(x: x, y: y, width: 1, height: 1))  // rows run top to bottom
            }
        }
        #expect(!ink.isNull)
        #expect(planted.contains(ink), "planted \(planted), painted \(ink)")
        #expect(planted.insetBy(dx: 1, dy: 1).width <= ink.width && planted.insetBy(dx: 1, dy: 1).height <= ink.height)
    }
}

@Suite("SensitiveText: whole-token coverage (second review, 2026-11-20)")
struct SensitiveTextCoverageTests {
    static let gluedApostrophe =
        String(repeating: "x", count: 65) + "o'" + String(repeating: "b", count: 33) + "@example.com"

    @Test(
        "W1: a matched address is covered with its whole whitespace-free token",
        arguments: ["ops!night@example.com", gluedApostrophe, "a@a.b.c.d.e.f.g.h.aa.example.technology"])
    func addressTokenIsWhole(token: String) throws {
        #expect(try detect("Contato: \(token) fim") == ["email:\(token)"])
    }

    @Test("W1: a matched number is covered with every adjacent digit group (R02)")
    func numberGroupsAreWhole() throws {
        #expect(try detect("Tel +44 2 0 7 9 4 6 0 9 5 8 fim") == ["phone:+44 2 0 7 9 4 6 0 9 5 8"])
    }

    @Test("N01: a match ending inside a grapheme is kept, widened to the whole grapheme")
    func matchInsideAGraphemeIsKept() throws {
        #expect(try detect("Contato: ana@exa.com\u{301} fim") == ["email:ana@exa.com\u{301}"])
    }

    @Test("N02: fragment offsets are UTF-16 offsets in the joined line")
    func fragmentOffsetsAreUTF16() {
        #expect(joinFragments([("😀", false), ("ana@x.com", true)]).offsets == [0, 2])
        #expect(joinFragments([("e", false), ("\u{301}ana@example.com", true)]).offsets == [0, 1])
    }

    @Test("W3: a box with no pixels in the image fails the sweep even when padding would reach it")
    func unmappableBoxesFailBeforePadding() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 50)
        for rect in [
            CGRect(x: 100.1, y: 10, width: 5, height: 5), CGRect(x: 10, y: 10, width: 0, height: 5),
            CGRect(x: 10, y: 50.5, width: 5, height: 5), CGRect.null,
        ] {
            #expect(throws: SensitiveTextError.regionOutsideImage, "\(rect)") {
                _ = try SensitiveTextScanner.finalRegions([(.email, rect)], within: bounds)
            }
        }
    }

    @Test("W5: the tile budget is checked before any job is allocated")
    func tileBudgetIsCheckedFirst() {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(throws: SensitiveTextError.tooManyTiles) {
                _ = try SensitiveTextScanner.tileJobs(
                    for: CGSize(width: 1_000_000, height: 1_000_000), pixelsPerPoint: 1, fineTileSide: 1024)
            }
        }
        #expect(elapsed < .milliseconds(500), "took \(elapsed)")
    }
}

@Suite("SensitiveText: whole-token pixels and budgets (second review, 2026-11-20)")
struct SensitiveTextCoveragePixelTests {
    @Test(
        "W1: the review's examples are covered pixel for pixel, whole token included", VisionRuntime.required,
        arguments: [
            "+44 2 0 7 9 4 6 0 9 5 8", "ops!night@example.com", SensitiveTextCoverageTests.gluedApostrophe,
            "a@a.b.c.d.e.f.g.h.aa.example.technology",
        ])
    func reviewExamplesAreCoveredWhole(token: String) async throws {
        let kind: SensitiveScreen.Kind = token.hasPrefix("+") ? .phone : .email
        let screen = try SensitiveScreen.renderItem(
            token, kind: kind, widthPoints: 1200, heightPoints: 120, scale: 2, pointSize: 14, x: 40, top: 80)
        let item = try #require(screen.planted.first)
        try #require(item.rect.maxX < CGFloat(screen.image.width) - 40, "token wider than the image")
        let regions = try await SensitiveTextScanner().sensitiveRegions(
            in: screen.image, pixelsPerPoint: 2, languages: [OCRRecognitionTests.english])
        let rects = regions.map {
            CGRect(x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width, height: $0.rect.height)
        }
        let (covered, total) = SensitiveTextBenchmarkTests.coverage(of: item.rect, by: rects)
        #expect(covered == total, "\(token): \(covered) of \(total) ink-box pixels; ink \(item.rect), masks \(rects)")
    }

    @Test(
        "W4: a 2200 px address across both middle crops of a 5120 px capture is covered (review §2)",
        VisionRuntime.required)
    func addressAcrossTheMiddleCrops() async throws {
        let (widthPoints, heightPoints, scale) = (2560, 300, 2)
        let address = "firstname.middlename.lastname.department.team.region@example.com"
        func render(_ pointSize: Double, at x: CGFloat) throws -> SensitiveScreen.Screen {
            try SensitiveScreen.renderItem(
                address, kind: .email, widthPoints: widthPoints, heightPoints: heightPoints, scale: scale,
                pointSize: pointSize, x: x, top: 200)
        }
        let probe = try #require(try render(30, at: 0).planted.first).rect
        let pointSize = (30 * 2200 / probe.width).rounded()
        let ink = try #require(try render(pointSize, at: 0).planted.first).rect
        let size = CGSize(width: widthPoints * scale, height: heightPoints * scale)
        let middle = TileLayout.standard(pixelsPerPoint: Double(scale))[1]
        let columns = tileRects(for: size, layout: middle).map { ($0.minX, $0.maxX) }
        try #require(columns.count == 2, "\(columns)")
        // Start 76 px before the second middle crop, as in the review (x 1460 to 3660).
        let x = (columns[1].0 - 76 - ink.minX).rounded()
        let screen = try render(pointSize, at: x)
        let item = try #require(screen.planted.first)
        try #require(item.rect.minX < columns[1].0 && item.rect.maxX > columns[0].1, "\(item.rect) vs \(columns)")
        let regions = try await SensitiveTextScanner().sensitiveRegions(
            in: screen.image, pixelsPerPoint: Double(scale), languages: [OCRRecognitionTests.english])
        let rects = regions.map {
            CGRect(x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width, height: $0.rect.height)
        }
        let (covered, total) = SensitiveTextBenchmarkTests.coverage(of: item.rect, by: rects)
        #expect(covered == total, "\(pointSize) pt: \(covered) of \(total); ink \(item.rect), masks \(rects)")
    }

    @Test("W5: a tile refuses matches past its budget as they arrive")
    func tileMatchBudgetIsEnforcedOnAppend() throws {
        var matches = SensitiveTextScanner.TileMatches()
        let box = CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
        for _ in 0..<SensitiveTextScanner.maximumMatchesPerTile { try matches.append(.phone, box) }
        #expect(throws: SensitiveTextError.tooManyMatches) { try matches.append(.phone, box) }
        #expect(matches.items.count == SensitiveTextScanner.maximumMatchesPerTile)
    }
}
