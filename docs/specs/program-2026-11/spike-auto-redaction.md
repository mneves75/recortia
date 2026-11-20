# Spike: detecting e-mail addresses and phone numbers for automatic redaction (FR-06)

Date 2026-11-19. Branch `spike/auto-redact` (from `feat/refresh-2026-11` at e8e80b6). Synthetic images
only; no real screenshots or screen content were read.

Environment: macOS 27.3 (26C5047e), Xcode 27.2 (27B52), Swift 6.4.2, Apple silicon. The package's
deployment target stays macOS 15. Variant C uses `@available(macOS 26, *)`, so `Package.swift`
was not changed. Other agents were working on the same Mac, so timings are noisy (see the two runs
below). The recall numbers were identical in both runs.

## What was built

- `Packages/RecortiaKit/Sources/Imaging/SensitiveText.swift`:
  - `SensitiveTextMatcher` (variant A), a port of Fosco's patterns. Credit: Fosco by Gabriel Buzzi,
    MIT, commit cf6ca8d4f176a5c6628a6ccfdb2c2db0abaa5ba8; the license is in the file header.
    Patterns compile once in `SensitiveTextMatcher.shared` (a `Result` with a typed
    `SensitiveTextError`). There is no `try!`, `fatalError` or force unwrap.
  - `SensitiveTextScanner.sensitiveRegions(in:pixelsPerPoint:languages:kinds:method:)`, which is
    `@concurrent` and honours cancellation. It uses Fosco's tile layout: a fine sweep at about 2 px/pt
    with 2048-px tiles overlapping by half, plus a coarse sweep at a quarter of that for headline text.
  - Up to 3 tiles at a time go through `TextRecognizer`'s new internal `recognizedObservations` entry
    point. The public `recognize` behaviour is unchanged; the existing OCR suites pass.
  - Fragments split by Vision are joined into lines before matching. Matches are boxed with
    `RecognizedText.boundingBox(for:)`, unioned with the line height, and also matched in the
    second and third candidate readings.
  - Duplicates across tiles are merged. Each box is outset by 15% of its height (at least 1 px),
    rounded outward to whole pixels and clamped to the image.
  - **A failing tile fails the whole sweep.** A partial sweep is never returned as complete, which
    matches the spec's fail-closed rule.
- Variant B (`method: .dataDetector`): the same sweep and lines, matched by `NSDataDetector`
  (`.phoneNumber`, plus `.link` whose scheme is `mailto`).
- Variant C (`method: .documents`): **a Vision API does report detected data with boxes.**
  - What I checked: in `MacOSX27.2.sdk` `Vision.swiftinterface`, `RecognizeDocumentsRequest`
    (macOS 26) returns `DocumentObservation`. Its `Container.Text.detectedData` is a list of
    `DataDetectorMatch`, each with a `match: DataDetection.DataDetector.Match` and a
    `boundingRegion: NormalizedRegion`.
  - `DataDetection.swiftinterface` (macOS 26) has `.emailAddress`, `.phoneNumber` and `.link` among
    `Match.SemanticDetails`.
  - Variant C runs that request per tile, with the same tiles, languages and no language
    correction. It reads `document.text.detectedData` plus each table cell's, and retries once on
    the CPU like `TextRecognizer`.
  - Not tried: `StringProtocol.dataDetectorMatches` from the DataDetection framework (macOS 26), which
    could replace `NSDataDetector` in B.
- `RecortiaFixtures/SensitiveScreen.swift` (does not import Imaging): screens with invented e-mail
  addresses and numbers planted at known rectangles, plus labelled look-alike decoys. The decoys
  are git remotes, versions, ISO and BR dates, times, `#` IDs, R$ amounts, IPs, UUIDs and hex
  colours. Content is seeded from the screen id, so it varies between screens and is identical
  across runs.
- Tests (`ImagingTests/SensitiveTextTests.swift`, 23 tests in 8 suites):
  - every pattern compiles;
  - Fosco's detector cases, ported with credit;
  - the brief's look-alike negatives;
  - tiles cover every pixel within budget;
  - outset rounding and clamping, and merging;
  - a Vision sweep over a planted screen;
  - cancellation.
- Benchmark (`ImagingTests/SensitiveTextBenchmarkTests.swift`): runs only with
  `RECORTIA_REDACT_BENCH=1` and is skipped when `RECORTIA_VISION_UNAVAILABLE=1`. The tile sweep needs
  `RECORTIA_REDACT_BENCH_TILES=1`.

## Method

- Matrix: 3 image sizes × scale 1×, 2× × font sizes 8, 10, 12, 14, 18, 24 pt × light, dark ×
  English, Portuguese surrounding text × single-column, dense multi-column. That is 288 screens and
  33,086 planted items, and every method scans every screen.
  - Image sizes: region 1200×800 pt, display 1512×982 pt, display 2560×1440 pt.
  - Single-column rows: label, item, decoy, then prose.
  - Dense rows: a name, e-mail, phone, date, amount and decoy table, repeated across the width.
- **Ground truth is ink.** A planted rectangle is the item's glyph image bounds, rounded outward to
  the pixels it touches. A first version used the typographic ascent box, which includes empty space
  above the glyphs; that would have scored correct masks as partial.
- **Full** means every pixel of the planted rectangle lies inside the union of the returned regions.
  **Partial** means some pixels are covered, but not all. **Missed** means none are.
- A **false positive** is a returned region that overlaps no planted item. It is labelled with the
  decoy it overlaps, if any.
- **Time** is the wall time of one `sensitiveRegions` call, after one warm-up scan per method. Each
  image size × scale cell has 48 runs.
- **Peak memory** is the process's `phys_footprint` sampled every 5 ms during a scan, minus the
  value at scan start. It is a rough figure: Vision keeps model buffers alive between scans.

Commands (log: `.scratch/logs/redact-bench.log`, ignored by git, not committed):

```sh
swift test --package-path Packages/RecortiaKit --filter SensitiveText          # 23 tests in 8 suites passed
RECORTIA_REDACT_BENCH=1 swift test --package-path Packages/RecortiaKit --filter SensitiveTextBenchmark
RECORTIA_REDACT_BENCH_TILES=1 swift test --package-path Packages/RecortiaKit --filter tileSideSweep
xcrun swift format lint --strict --recursive Packages/RecortiaKit/Sources Packages/RecortiaKit/Tests
```

## Results

### Overall (identical in both runs)

| method | planted | full (recall) | partial | missed | false-positive regions |
|---|---|---|---|---|---|
| A patterns | 33086 | 31005 (93.7%) | 299 | 1782 | 63 |
| B NSDataDetector | 33086 | 30484 (92.1%) | 437 | 2165 | 3303 |
| C Vision documents | 33086 | 30266 (91.5%) | 438 | 2382 | 3205 |

### False positives by decoy category

| category | A | B | C |
|---|---|---|---|
| `#` IDs (`#12345678901`) | 35 | 1524 | 1494 |
| git remotes | 22 | 1579 | 1591 |
| UUIDs | 6 | 112 | 84 |
| BR dates | 0 | 42 | 13 |
| ISO dates | 0 | 14 | 9 |
| amounts | 0 | 19 | 2 |
| IPs | 0 | 11 | 10 |
| time / other text | 0 | 2 | 2 |

The system detectors treat `git@github.com:…` as an address and an 11-digit `#` ID as a phone
number. A's remaining false positives come from OCR damage: a `#` or `-` was lost before a digit run,
or a git remote was misread.

### Time and memory per image (second run; p50 / p95 / max ms, peak MB)

| image | scale | A | B | C |
|---|---|---|---|---|
| region 1200×800 | 1× | 375 / 676 / 785, 138 | 362 / 570 / 701, 134 | 552 / 1295 / 2402, 132 |
| region 1200×800 | 2× | 353 / 774 / 1067, 148 | 366 / 876 / 1285, 134 | 691 / 1786 / 3384, 134 |
| display 1512×982 | 1× | 509 / 983 / 1517, 142 | 544 / 1136 / 1413, 72 | 948 / 3130 / 4793, 85 |
| display 1512×982 | 2× | 391 / 1162 / 1277, 156 | 372 / 1078 / 2109, 75 | 822 / 3163 / 5143, 128 |
| display 2560×1440 | 1× | 1178 / 2490 / 3003, 189 | 1173 / 2536 / 2727, 165 | 1601 / 6430 / 8652, 169 |
| display 2560×1440 | 2× | 960 / 2238 / 2760, 208 | 1024 / 2166 / 2451, 148 | 1610 / 4691 / 6798, 132 |

In the first run, on a busier machine, A's p95 was 1403, 989, 1599, 1629, 3377 and 2648 ms in the
same row order, and C's p95 reached 9170 ms. Treat these as order-of-magnitude figures. A and B cost
the same, because OCR dominates. C costs about 1.5–3× more.

### Misses by category (A; B and C follow the same shape, 1–3 points lower)

| font | 1× | 2× |
|---|---|---|
| 8 pt | 85.9% | 86.0% |
| 10 pt | 95.7% | 94.8% |
| 12 pt | 99.5% | 99.8% |
| 14 pt | 99.6% | 99.6% |
| 18 pt | 99.9% | 99.7% |
| 24 pt | 99.9% | 99.9% |

- **Size** decides the outcome. From 12 pt up, A covers 99.5–100% of items. At 8 and 10 pt it does
  not.
- **Scale** barely matters: 93.7% at both 1× and 2×. The fine sweep already resamples to 2 px/pt.
- **Theme:** dark 96.3%, light 91.1%. The gap is only at 8–10 pt: light 8 pt 80.8% versus dark
  8 pt 91.0%. From 12 pt up the themes match.
- **Language:** EN 93.9%, PT-BR 93.6%, which is no difference.
- **Layout:** dense 94.0%, single-column 91.8%. Single-column screens hold fewer items, so a few bad
  8 pt screens weigh more.
- **Kind and format:** for A, phones score 94.8% and e-mails 92.6%; every format is between 91% and
  96%. B and C lose BR formats most: br-mobile 86.9%, against 93.5% for A.
- **Image size** looks odd until it is crossed with font size. At 8 pt: 1512×982 65.7%,
  1200×800 81.5%, 2560×1440 94.4%. At 10 pt: 81.0%, 99.1% and 99.8%.
  - The worst screens are 8–10 pt on 1512×982, down to 0% on `1512x982@2x-8pt-dark-en-US-singleColumn`.
  - They fail almost the same way for all three methods, so the loss is in OCR, not in the matching.
  - These are the screens whose fine tiles are largest: about 2024×1964 px, close to 4 MP. Vision
    downsamples such a tile, and 8–10 pt text is lost.

### Fine tile side vs small-text recall (A only; 16 screens per row)

| image | font | 2048 (current) | 1448 | 1024 | p50 / p95 ms at 2048 → 1024 |
|---|---|---|---|---|---|
| region 1200×800 | 8 pt | 81.5% | 99.2% | 99.5% | 329 / 480 → 623 / 1182 |
| region 1200×800 | 10 pt | 99.1% | 99.0% | 99.2% | 383 / 459 → 577 / 675 |
| region 1200×800 | 12 pt | 99.3% | 93.4% | 99.9% | 292 / 336 → 751 / 1123 |
| display 1512×982 | 8 pt | 65.7% | 99.4% | 98.9% | 511 / 656 → 1040 / 1310 |
| display 1512×982 | 10 pt | 81.0% | 98.4% | 99.7% | 488 / 762 → 1014 / 1616 |
| display 1512×982 | 12 pt | 99.9% | 99.8% | 99.9% | 412 / 508 → 975 / 1184 |

1024-px fine tiles (about 1 MP) bring 8–10 pt text to 98.9–99.7%, at roughly 2–3× the time. 1448 is
not monotonic (93.4% at 12 pt on the region), so it is not a safe middle ground. I did not change
the default; the committed code and the main log both use 2048.

## Recommendation

**Use A, the pattern matcher, with 1024-px fine tiles, and build the plan's alternative wait
design.**

- **Accuracy:** A has the highest recall in every cut, and about 50 times fewer false positives than
  B and C: 63 against more than 3,200.
- **Formats:** A covers Brazilian notations that the system detectors miss.
- **Platform:** A runs on macOS 15 and needs no macOS 26 API.
- **Small text:** the tile sweep shows that A's remaining small-text loss is tile size, not the
  patterns.

**Latency:** p95 is above the plan's ~0.5 s threshold at every size, even with 2048 tiles. 1024 tiles
roughly double it. So the visible-wait design is out. The plan's alternative fits:

1. Open the editor at once.
2. Lock its exports and the automatic batch until the masks land as one undo step.
3. Fail closed on error, cancel or deadline.

A deadline around 5–8 s would cover the measured 2560×1440 max under load (about 3–3.8 s with 2048
tiles; not yet measured with 1024).

**Strongest alternative: C, Vision `RecognizeDocumentsRequest` detected data.**

- For: it is Apple-maintained, so formats improve with the OS without our patterns, and it gives
  structure for free (tables, lists).
- Against:
  - 2 points less recall than A;
  - about 50 times more false positives (git remotes, `#` IDs, UUIDs);
  - 1.5–3× slower, with p95 up to 9 s on 2560×1440 under load;
  - needs macOS 26;
  - weaker on BR mobile numbers.
- Choose it only if pattern upkeep is judged costlier than masking look-alikes. The false positives
  are recoverable, because masks can be deleted. A miss is not recoverable.

B adds nothing over A: it costs the same, has lower recall and the same false-positive problem as C.

## Limits

- Synthetic system-font text on flat backgrounds only. There are no photos, coloured UI chrome, link
  styling, sub-pixel AA, emoji or non-Latin scripts. Real captures will score lower. This benchmark
  ranks the methods; it does not qualify the feature.
- **About 6% of planted items are still missed with 2048 tiles.** The feature must remain the review
  aid the spec describes. It cannot promise that nothing sensitive remains.
- Peak memory is approximate: process footprint sampled at 5 ms, with Vision caches warm.
- Partial coverage, 299 items for A: I did not analyse the cause, and the benchmark does not
  separate a short sub-line box from a match on only part of the item. The 15% outset was not tuned
  against the benchmark.
