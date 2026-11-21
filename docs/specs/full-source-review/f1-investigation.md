# F-1 investigation: designed system fonts resolving to nil

2026-11-21, branch `fix/t2-f1-font-nil` (based on `train/t2` at 78dd566). Host: 18-core Apple
silicon Mac, 64 GB, macOS 27.3 (26C5047e), Xcode 27.2 (27B52). The machine was shared with other
gates, VMs and builds; load averages are recorded per process.

## Result

Cause found and fixed. `NSFont(descriptor:size:)`, and less often `NSFontDescriptor.withDesign`
on the descriptor of `NSFont.systemFont(ofSize:)`, return nil when **one thread releases font
objects while another thread resolves the same typeface**. Core Text, given the same descriptor at
the same moment, matches and creates the correct font. Machine load is not the cause. It widens
the window, which is why the incident showed up under load.

`TextLayout.nativeFont` now builds designed fonts from Core Text objects only:
`CTFontCreateUIFontForLanguage(.system)` → `CTFontCopyFontDescriptor` → `withDesign` →
`CTFontDescriptorCreateMatchingFontDescriptor` → `CTFontCreateWithFontDescriptor`. `withDesign`
only edits the descriptor's attributes. The bounded retry (two repeats of the same call) and
per-stage errors remain. Two typed errors are new: `unavailableSystemFont` and `mismatchedFont`.
The created font must carry the matched PostScript name, so a Core Text substitute font fails
instead of rendering silently. Standard, outlined and boxed text still uses
`NSFont.systemFont(ofSize:)`, which never returns nil.

## Harness

`Packages/RecortiaKit/Tests/ImagingTests/FontResolutionStressTests.swift`, enabled only by
`RECORTIA_FONT_STRESS=1`. Variants resolve rounded, monospaced and serif at sizes 8–96 on 8 or 16
workers, one of them on the main actor. They print one `F1STRESS` JSON line per process.
`_SIZES=fresh` defeats font caches. `_POOL=1` wraps each resolution in an autorelease pool, so
fonts are released while other workers resolve. Cold processes run the test bundle directly,
0.2 s per process:

```sh
D=$(xcode-select -p)
cd Packages/RecortiaKit && swift build --build-tests
DYLD_FRAMEWORK_PATH=$D/Platforms/MacOSX.platform/Developer/Library/Frameworks \
DYLD_LIBRARY_PATH=$D/Platforms/MacOSX.platform/Developer/usr/lib \
RECORTIA_FONT_STRESS=1 RECORTIA_FONT_STRESS_VARIANTS=product RECORTIA_FONT_STRESS_ROUNDS=1 \
RECORTIA_FONT_STRESS_WORKERS=16 RECORTIA_FONT_STRESS_POOL=1 \
"$D/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper" \
  --test-bundle-path .build/debug/ImagingTests.xctest/Contents/MacOS/ImagingTests \
  --testing-library swift-testing --filter FontResolutionStress
```

The loops ran 6–9 such processes in parallel for 1–5 minutes per experiment. Each loop checked for
a native E2E app process under `.build/dd*` and would have stopped if one was running.

## Measurements

Variants: `nsfont` is the old path without its retry. `product` is the shipped
`TextLayout.nativeFont`, retry included. `ctpath` uses Core Text match and create on the
AppKit-designed descriptor. `ctbase` is the final fix. `nsfont-warm` is `nsfont` after one
serial resolution of each design.

| Run | Conditions | Variant: failing processes / processes, failed calls / attempts |
|---|---|---|
| E1 | fresh, 8 workers, load 69–96 | nsfont 1/146, 4/1,247,424 (all monospaced, one on main); nsfont-weight, ctcreate, ctmatch 0 (≈1.25M each); monospaced-api 0/421,504 |
| E2 | fresh, 8 workers, load 69–143 | nsfont 1/1,326, 2/11,329,344 |
| E3 | fresh, 16 workers, load 60–88 | nsfont 6/1,038, 44/4,434,336; nsfont-warm 14/1,038, 120/4,434,336; ctpath 0/1,038, 0/4,434,336 |
| E4 | fresh, 16 workers, load 51–85 | product (old) 1/135, 2 × `unavailableFont(.rounded)` off main; ctpath 0/135; nsfont-matched 0/135 |
| E5 | fresh, interim fix (Core Text final stage only), load 40–77 | product 1/1,548, 5 × `unavailableFontDesign` (one on main); nsfont-warm 12/1,548, 132 |
| E6 | churn (`_POOL=1`), integer, 16 workers, load 51–168, interim fix | nsfont 693/693, 34,516 (31,278 font stage, 3,238 withDesign); ctpath 561/693, 813,927 withDesign; product 298/693, 64,640 |
| E7 | same, no pool, load 46–79 | nsfont, product, ctpath 0/1,620 each |
| E8 | churn, **one worker**, load 42–59 | nsfont, product, ctpath 0/622 each |
| E9 | churn, 16 workers, load 34–47, interim fix | ctbase 0/723, 0/3,088,656; nsfont 723/723, 38,241; product 334/723, 95,664 |
| E10 | churn, 16 workers, load 20–32, **final fix** | product 0/618, 0/1,760,064; ctbase 0/618; nsfont 618/618, 37,092 |
| E11 | fresh, 16 workers, load 30–208, **final fix** | product 0/1,005, 0/2,862,240; ctbase 0/1,005; nsfont-warm 8/1,005, 75 |

Each `nsfont` nil was probed at once with Core Text on the same descriptor. All 166 recorded
probes (E2–E3: 79 rounded, 48 monospaced, 39 serif) returned the correct font from both
`CTFontDescriptorCreateMatchingFontDescriptor` and `CTFontCreateWithFontDescriptor`. The failed
call took 0.04–302 ms (median 0.28 ms). Of 170 natural nils (E1–E3), 30 recovered within the two
immediate repeats that the product makes. The rest recovered only after a 1–100 ms pause, which is
why the bounded retry did not contain the incident. None failed after 1 s.

The shipped retry was not enough before the fix: E4 reproduced the recorded incident error
(`unavailableFont(.rounded)`, off main). Under churn, an old-path `nsfont` call failed in every
process. With E3's interleaving, the chance that all 20 natural failing processes would avoid the
`ctpath` third by luck is (2/3)^20 ≈ 3 × 10⁻⁴. Under churn the contrast is 0 of 723 against 723 of
723.

## Hypotheses

1. **`withDesign` returning nil.** Not the main stage: none in natural runs of the old path
   (≈43M attempts). It does occur under churn (E6) and once naturally after the interim fix (E5).
   In UIFoundation, `withDesign` returns nil only when its input lacks
   `kCTFontDescriptorTextStyleAttribute`. So the descriptor of `NSFont.systemFont(ofSize:)` came
   back incomplete, which is the same race at an earlier stage. The final fix takes the base
   descriptor from Core Text.
2. **Font server (fontd) timing out under load.** Falsified. Core Text matching, which uses the
   font server, succeeded at the moment of all 166 probed nils. `log show` (info and debug) around
   the E1 failures shows only fontd's XPC connection lines, with no errors. Failures need two
   threads in one process (E8: 0 with one worker). Failing processes are independent in time:
   only two pairs coincide, each from the same parallel batch.
3. **First-use registration racing across threads.** Falsified as stated. A serial warm-up raised
   the rate instead of removing it (E3: 14 against 6 failing processes; E5: 12 against 0). Under churn, failures spread over the whole
   process (p10 57 ms, p50 351 ms, p90 551 ms of a 592 ms run), not only its start.
4. **Other APIs.** Core Text matching and creation: 0 failures in every run (ctpath, ctcreate,
   ctmatch; ctbase also under churn). `systemFont(ofSize:weight:)` + `withDesign`: 0 in E1, too
   few events to tell apart, and not tried under churn. `monospacedSystemFont`: 0 in E1;
   monospaced only. `NSFont(descriptor:)` on a matched, strongly held descriptor: 0/135 (E4),
   too small a sample and still inside AppKit, so not chosen.
5. **Release race (found under churn).** Confirmed. An autorelease pool around each resolution
   turns rare failures into failures in every process for the old path (E6, E9, E10), with 0
   failures for one worker (E8). This also explains why the process-wide lock was falsified
   before: our lock serialized our calls, but the releases happen outside it.

## Mechanism (from disassembly; inferred, not traced)

UIFoundation in the dyld shared cache of this build (`ipsw dyld disass`):
`+[NSFont fontWithDescriptor:size:]` looks up `+[__NSFontTypefaceInfo typefaceInfoForKnownFontDescriptor:]`.
If that misses, it calls `CTFontDescriptorCreateMatchingFontDescriptor` and
`typefaceInfoForFontDescriptor:`, then returns `-fontInstanceForFontDescriptor:size:affineTransform:renderingMode:`.
The typeface table and the per-typeface font table are `NSMapTable`s with weak values, behind
`__NSFontTypefaceInfoTableLock` and `__NSFontLock`. A table entry is reused only while its
`retainCount` is non-zero and `_validate` passes. `-normalizedFontDescriptor` is an
`objc_loadWeak`, and `-newPlatformFontWithKey:` returns nil when that weak load is nil. It
otherwise calls the same `CTFontCreateWithFontDescriptor` that the fix calls. So an entry whose
objects are being deallocated on another thread can be found and used. Its weak descriptor then
reads nil, and the lookup returns nil. Under load, threads are preempted between those steps
longer, so the window widens. The sequence of instructions is read, not observed at run time.

## Fix and regression tests

- `TextLayout.nativeFont` uses the Core Text chain above. At idle, its fonts are `CFEqual` to the
  old `NSFont` results, with equal names, metrics, variation axes and glyph advances, for rounded
  and monospaced at 886 sizes from 7.5 to 450 pt (scratch probe). The base font is `CFEqual` to
  `NSFont.systemFont(ofSize:)`.
- `TextLayoutConcurrencyTests.resolutionWhileFontsAreReleased` runs in the normal gate: 16
  workers, 2,848 resolutions, each in an autorelease pool. With the old resolution body swapped
  in temporarily, 5 of 5 runs failed (7–52 `unavailableFont` per run). The fixed code passed 25
  of 25 runs.
- `designedFontsMatchAppKit` guards rendering parity. It skips a nil reference, because that nil
  is F-1 itself. `mismatchedFontIsReported` guards the substitute-font check. `boundedRetries`
  covers all three nullable stages.
- The harness `product` variant fails on any error. It is the opt-in regression check under
  load and churn (E10, E11: 0).

## Open

- Native E2E (`text-font-designs`, `text-decorations`, `text-layout-failure`, `curved-arrows`,
  `appearance-contrast`) was not run here. It checks editing and export with the Core Text font
  objects. UIFoundation builds its `NSFont` instances with the same `CTFontCreateWithFontDescriptor`
  call, which is why we expect no difference.
- Standard, outlined and boxed text still uses `NSFont.systemFont(ofSize:)`. It never returns
  nil, and no failure was attributed to it. Its descriptor is affected by the same race, but only
  the font object is used.
- The AppKit defect is unreported. A minimal reproduction for Apple is two threads, one
  resolving `NSFont(descriptor:size:)` for a designed system font while another releases fonts
  in autorelease pools.
