# Spike: detecting e-mail addresses and phone numbers for automatic redaction (FR-06)

Date 2026-11-19. Branch `spike/auto-redact` (from `feat/refresh-2026-11` at e8e80b6). Synthetic images
only; no real screenshots or screen content were read.

Environment: macOS 27.3 (26C5047e), Xcode 27.2 (27B52), Swift 6.4.2, Apple silicon. The package's
deployment target stays macOS 15. Variant C uses `@available(macOS 26, *)`, so `Package.swift`
was not changed. Other agents were working on the same Mac, so timings are noisy (see the two runs
below). The recall numbers were identical in both runs.

The detector was then hardened against the cross-model review (R02–R17) and two security findings,
and the benchmark rerun for method A only; see [Hardening](#hardening-review-2026-11-19) and
[Hardened detector results](#hardened-detector-2048-vs-1024-fine-tiles).

## What was built

- `Packages/RecortiaKit/Sources/Imaging/SensitiveText.swift`:
  - `SensitiveTextMatcher` (variant A), a port of Fosco's patterns. Credit: Fosco by Gabriel Buzzi,
    MIT, commit cf6ca8d4f176a5c6628a6ccfdb2c2db0abaa5ba8; the license is in the file header.
    Patterns compile once in `SensitiveTextMatcher.shared` (a `Result` with a typed
    `SensitiveTextError`). There is no `try!`, `fatalError` or force unwrap.
  - `SensitiveTextScanner.sensitiveRegions(in:pixelsPerPoint:languages:kinds:method:)`, which is
    `@concurrent` and honours cancellation. It started from Fosco's tile layout: a fine sweep at about
    2 px/pt with 2048-px tiles overlapping by half, plus a coarse sweep at a quarter of that for
    headline text. Hardening added a middle sweep (see below).
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
- Tests (`ImagingTests/SensitiveTextTests.swift`, 23 tests in 8 suites at the spike; 39 tests in 12
  suites after hardening, plus 3 in the gated benchmark file):
  - every pattern compiles;
  - Fosco's detector cases, ported with credit;
  - the brief's look-alike negatives;
  - tiles cover every pixel within budget;
  - outset rounding and clamping, and merging;
  - a Vision sweep over a planted screen;
  - cancellation.
- Benchmark (`ImagingTests/SensitiveTextBenchmarkTests.swift`): runs only with
  `RECORTIA_REDACT_BENCH=1` and is skipped when `RECORTIA_VISION_UNAVAILABLE=1`. After hardening it
  measures A at 2048 and 1024 fine tiles; `RECORTIA_REDACT_BENCH_ALL_METHODS=1` adds B and C at 2048.
  The seam experiment is the separate test `SensitiveTextBenchmarkTests/seams`.

## Hardening (review 2026-11-19)

Each change has a regression test that failed first. Commits are on `spike/auto-redact`.

| item | change | commit |
|---|---|---|
| R02 | International numbers keep whole digit groups up to 11 digits (+1), 13 (+55) or 15 (E.164), instead of stopping after 10. | 9875be5 |
| R03 | Middle sweep at 1 px/pt in 2048-px tiles overlapping by half: text up to 1024 pt wide lies whole in one tile. Without it, an address whose "@" fell past one 1024 tile's edge left 82 px of ink unmasked. | f1134d6 |
| R04 | A fragment run is also read with the gaps next to "@", a dot or a hyphen closed. | c7486f5 |
| R05 | A match that cannot be mapped onto the image throws `regionOutsideImage`. | c7486f5 |
| R06 | `git@` suppresses a match only before `:path` (SSH remote syntax). | 9875be5 |
| R07 | Local parts accept letters of any script and inner apostrophes. | 9875be5 |
| R08 | Compact NANP numbers and BR numbers without an area code are found after a phone label ("Phone:", "Celular", "Tel" ...); bare digit runs stay unmasked. | 9875be5 |
| R09 | Cancellation is checked again after the final merge. | c7486f5 |
| R12 | Budgets of 1024 tiles, 512 matches per tile and 4096 per sweep; exceeding one throws. | c7486f5 |
| R13 | Bounded repetitions, run-start anchoring, 8192-unit windows with transparent bounds, phone label as a prefix. 64 KB pathological lines take under a second each. | 9875be5, 56b6f7b |
| R17 | Regions are merged in a total geometry order. | c7486f5 |
| S1 | An "@" after more than 64 local characters (glued prefix, CJK or Thai without spaces) is matched from 64 characters before it. The mask may be wider than the address but never narrower. | 5c120be |
| S2 | Patterns declare a UTF-16 length bound from their own repetition limits (longest: 1067 units). The window overlap is 2048, and the matcher refuses to build if any bound reaches it. | 5c120be |
| W1 | Second review (2026-11-20): every match is widened to its whole token, an address's run of non-whitespace and a number's adjacent digit groups. Over-coverage is accepted; a visible prefix or suffix is not. | 14a2559 |
| W2 | One span representation: UTF-16 `NSRange` from regex output to box mapping; a range that cannot be mapped throws `rangeUnmappable`. | 14a2559 |
| W3 | Null, degenerate, non-finite or outside-the-image boxes fail the sweep before padding. | 14a2559 |
| W4 | No height filter after matching. The review's 2200 px address across both middle crops of a 5120 px capture is fully covered, even with the old filter restored, so no edge extension was added. | 14a2559 |
| W5 | Tile count checked before allocation, the per-tile match budget enforced on append, 2048 observations per tile, cancellation injected after finalization's entry check, the sampler cancelled on every exit. The default fine tile is now 1024 px (decisions.md). | 14a2559, e41b276 |
| R10, R11, R14–R16 | Benchmark: area precision, ground truth from painted pixels in the composed line, metadata-only outcomes with absolute and baseline memory, content fixed across conditions, 1024 tiles at 2560×1440. | 21f8d51, 791abfb |

## Method

- Matrix: 3 image sizes × scale 1×, 2× × font sizes 8, 10, 12, 14, 18, 24 pt × light, dark ×
  English, Portuguese surrounding text × single-column, dense multi-column. That is 288 screens and
  33,086 planted items, and every method scans every screen.
  - Image sizes: region 1200×800 pt, display 1512×982 pt, display 2560×1440 pt.
  - Single-column rows: label, item, decoy, then prose.
  - Dense rows: a name, e-mail, phone, date, amount and decoy table, repeated across the width.
- **Ground truth is ink.** In the spike run, a planted rectangle was the item's glyph image bounds,
  rounded outward. That estimate sat about 1 px above the painted ink. After hardening it is the
  bounding box of every pixel the item's glyphs touch in the composed line, and a unit test checks it
  against the painted pixels.
- **Full** means every pixel of the planted rectangle lies inside the union of the returned regions.
  **Partial** means some pixels are covered, but not all. **Missed** means none are.
- A **false positive** is a returned region that overlaps no planted item. It is labelled with the
  decoy it overlaps, if any.
- **Time** is the wall time of one `sensitiveRegions` call, after one warm-up scan per method. Each
  image size × scale cell has 48 runs.
- **Peak memory** is the process's `phys_footprint` sampled every 5 ms during a scan, minus the
  value at scan start. It is a rough figure: Vision keeps model buffers alive between scans.

Commands for the spike run (log: `.scratch/logs/redact-bench.log`, ignored by git, not committed):

```sh
swift test --package-path Packages/RecortiaKit --filter SensitiveText          # 23 tests in 8 suites passed
RECORTIA_REDACT_BENCH=1 swift test --package-path Packages/RecortiaKit --filter SensitiveTextBenchmark
RECORTIA_REDACT_BENCH_TILES=1 swift test --package-path Packages/RecortiaKit --filter tileSideSweep
xcrun swift format lint --strict --recursive Packages/RecortiaKit/Sources Packages/RecortiaKit/Tests
```

Commands for the hardened run (logs `.scratch/logs/t1d-bench-full.log`, `t1d-bench-seams.log`,
`t1d-full-tests.log`, ignored by git):

```sh
RECORTIA_REDACT_BENCH=1 xcrun swift test --package-path Packages/RecortiaKit --filter SensitiveTextBenchmark
RECORTIA_REDACT_BENCH=1 xcrun swift test --package-path Packages/RecortiaKit --filter SensitiveTextBenchmarkTests/seams
xcrun swift test --package-path Packages/RecortiaKit --parallel                    # all suites passed
xcrun swift format lint --strict --recursive --parallel Packages/RecortiaKit/Sources Packages/RecortiaKit/Tests
```

## Results

### Hardened detector, 2048 vs 1024 fine tiles

**These numbers predate W1–W4.** Whole-token coverage and the removed coarse-height filter can only
add masked pixels, so recall can only rise and area precision may fall. The run was not repeated.

Run 2026-11-19 to 2026-11-20 (wall time 2117 s), method A, the full matrix (288 screens, 33,472
planted items). Content is now the same across scale, font size and theme, so these counts are not
comparable item for item with the spike run below.

**Timings are not usable as absolute figures.** Load average was 157–183 on 18 cores when the run
ended, against an unknown but lower load during the spike run. The same 2048 configuration measured
about 5 times slower here than in the spike, so read only the ratio between tile sizes.
Area precision is masked pixels on planted ink divided by masked pixels. About half of every mask
is the 15% outset and the line-height box around the ink, so roughly 54% is the ceiling of the
current boxing, not a sign of masks swallowing content.

| fine tile | recall (full) | partial | missed | false-positive regions | area precision |
|---|---|---|---|---|---|
| 2048 | 96.6% (32340) | 242 | 890 | 387 | 53.4% |
| 1024 | 99.2% (33220) | 30 | 222 | 495 | 53.7% |

| image | scale | 2048: recall, area precision, p50 / p95 ms, peak MB above baseline / absolute | 1024: same |
|---|---|---|---|
| region 1200×800 | 1× | 97.1%, 53.8%, 378 / 650, 132 / 336 | 99.9%, 54.0%, 641 / 1136, 109 / 310 |
| region 1200×800 | 2× | (recall as above), 450 / 799, 80 / 407 | (as above), 821 / 1625, 43 / 388 |
| display 1512×982 | 1× | 90.4%, 50.8%, 837 / 2299, 156 / 451 | 99.8%, 50.9%, 2039 / 4856, 104 / 415 |
| display 1512×982 | 2× | (as above), 1135 / 4858, 180 / 392 | (as above), 3334 / 8283, 125 / 350 |
| display 2560×1440 | 1× | 99.0%, 54.4%, 3289 / 14356, 249 / 426 | 98.9%, 54.9%, 6844 / 24029, 230 / 409 |
| display 2560×1440 | 2× | (as above), 2356 / 11599, 268 / 551 | (as above), 6092 / 14540, 197 / 540 |

Recall and area precision are per image size, both scales together. Recall by font size, 2048 → 1024:
8 pt 91.7–92.9% → 98.2–98.6%; 10 pt 96.9–98.7% → 99.2–99.8%; 12 pt 98.5–99.9% → 99.7–99.8%; from
14 pt up both are 99.9–100%.

False positives by decoy, 2048 / 1024: git remotes 302 / 388, UUIDs 38 / 51, `#` IDs 37 / 45, other
categories 1–4 each. Git remotes went from 22 in the spike to about 300. OCR reads the remote itself
correctly at 10 pt and up (a probe printed `git@github.com:org/repo2.git`), so the likely cause,
inferred and not proven, is R06: a tile that cuts the line just after `.com` leaves no `:path` to
suppress the match, while the whole copy in the neighbouring tile is suppressed. Dropping matches at
tile edges would fail open for text wider than the overlap, so this is left as a precision cost. The
UUID rise was not analysed.

Seam experiment (review §2, `SensitiveTextBenchmarkTests/seams`: 2560×400 pt at 2×, the address
`firstname.middlename.lastname.department.team.region@example.com` inside the first fine tile, and
with its "@" just past that tile's edge while it starts at least 40 px before the next tile):

| fine tile | inside a tile (12, 14, 18, 24 pt) | across a seam |
|---|---|---|
| 2048 | full, 1 region each | 24 pt: full, 1 region (smaller sizes cannot straddle a 2048 tile) |
| 1024 | full, 1 region each | 14 and 18 pt: full, 1 region (12 pt cannot straddle; 24 pt would leave the image) |

Before the middle sweep, the 1024 unit test version of this experiment masked from x 467 an address
whose ink began at x 385.

### Spike run: method comparison (before hardening)

#### Overall (identical in both runs)

| method | planted | full (recall) | partial | missed | false-positive regions |
|---|---|---|---|---|---|
| A patterns | 33086 | 31005 (93.7%) | 299 | 1782 | 63 |
| B NSDataDetector | 33086 | 30484 (92.1%) | 437 | 2165 | 3303 |
| C Vision documents | 33086 | 30266 (91.5%) | 438 | 2382 | 3205 |

#### False positives by decoy category

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

#### Time and memory per image (second run; p50 / p95 / max ms, peak MB)

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

The spike's per-font recall and its 2048/1448/1024 tile-side table are superseded by the
hardened results above.

## Recommendation

**Use A, the pattern matcher, with 1024-px fine tiles (plus the middle and coarse sweeps), and build
the plan's alternative wait design.**

- **Tile size:** 1024 misses 222 items against 890 for 2048 (recall 99.2% against 96.6%). It keeps
  8 pt text at 98.2–98.6% where 2048 loses 7–8%, with the same area precision (53.7% / 53.4%) and
  peak memory no higher (at most 230 MB above baseline, 540 MB absolute). It costs about 2× the
  time (p50 at 2560×1440: 6.8 s / 6.1 s against 3.3 s / 2.4 s under this run's load) and 108 more
  false-positive regions, mostly git remotes.
- **Accuracy (spike run):** A has the highest recall in every cut, and about 50 times fewer false
  positives than B and C: 63 against more than 3,200.
- **Formats:** A covers Brazilian notations that the system detectors miss.
- **Platform:** A runs on macOS 15 and needs no macOS 26 API.
- **Small text:** A's remaining small-text loss was tile size, not the patterns; 1024 tiles recover
  most of it.

**Latency:** p95 is above the plan's ~0.5 s threshold at every size, even with 2048 tiles. 1024 tiles
roughly double it. So the visible-wait design is out. The plan's alternative fits:

1. Open the editor at once.
2. Lock its exports and the automatic batch until the masks land as one undo step.
3. Fail closed on error, cancel or deadline.

The editor-timing decision itself is settled in `decisions.md` (R01).

**The deadline is not yet measurable.** The hardened run's 2560×1440 p95 with 1024 tiles was 14.5–24 s
at load average about 170. That shows only that a 5–8 s deadline needs a measurement on an idle Mac,
cold and warm, before it is chosen.

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

## Integration and deadline (T1d, 2026-11-20)

Branch `feat/t1d-auto-redact` merges this spike into `train/t1` and ships method A with 1024-px fine
tiles behind the opt-in Privacy setting. The editor opens at once and stays locked until the masks
land (decisions.md, "Auto-redaction timing"). Detection runs through
`SensitiveTextScanner.sensitiveRegions(of:in:pixelsPerPoint:languages:)`, which reads the capture
from `ImageStore` inside Imaging. The data-detector and document variants remain for this benchmark
only.

**Deadline: 8 s, provisional.** The rule is 1.5 × the warm p99 at 2560×1440 2×, rounded up to a
whole second and clamped to 3–10 s, measured when the console is unlocked and idle (HIDIdleTime at
least 300 s) and the load average is under 8. No such window came during T1d. Every check found the
console locked, with load averages between 17 and 42 on 18 cores. So the deadline is the brief's
fallback, `EditorModel.autoRedactionDeadline = .seconds(8)`, until the measurement below runs.

Measurement, one process per case so its first scan is the cold one after launch:

```sh
for c in 2560x1440@2 2560x1440@1 1440x900@2 1440x900@1; do
  RECORTIA_REDACT_LATENCY=1 RECORTIA_REDACT_LATENCY_CASE=$c RECORTIA_REDACT_LATENCY_RUNS=30 \
    xcrun swift test --package-path Packages/RecortiaKit --filter SensitiveTextLatencyTests \
    >> .scratch/logs/t1d-latency.log 2>&1
done
```

The only run so far was a functional smoke test, not a measurement: 1440×900 1×, cold 847 ms,
2 warm runs at 624 and 757 ms, with the console locked and load about 36
(`.scratch/logs/t1d-latency-smoke.log`).

## Limits

- Synthetic system-font text on flat backgrounds only. There are no photos, coloured UI chrome, link
  styling, sub-pixel AA, emoji or non-Latin scripts. Real captures will score lower. This benchmark
  ranks the methods; it does not qualify the feature.
- **About 0.8% of planted items are still missed with 1024 tiles (3.4% with 2048).** The feature
  must remain the review aid the spec describes. It cannot promise that nothing sensitive remains.
- Misses are not yet attributed: the benchmark does not record OCR candidates or match ranges for a
  failed item, so a miss in OCR, in matching and in boxing look the same (review R15, second half).
- Peak memory is approximate: process footprint sampled at 5 ms, with Vision caches warm.
- Partial coverage (299 items in the spike run; 30 with 1024 tiles after hardening): I did not analyse the cause, and the benchmark does not
  separate a short sub-line box from a match on only part of the item. The 15% outset was not tuned
  against the benchmark.
