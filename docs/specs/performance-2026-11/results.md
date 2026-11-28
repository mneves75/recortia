# Performance hillclimb 2026-11: results

Owner request (2026-11): lower latency, bytes produced and lag, one measured hypothesis at a time,
without trading any privacy invariant (ShareSnapshot, masks before resample, staleness checks).
Baseline: `main` at ad980f5 (0.16.0). Head: branch `perf/hillclimb-security-2026-11`; the final
A/B ran against 0af8c80, and later commits change only tests.

## Method

- Harness: `bench/` is a frozen Swift package bound to `Packages/RecortiaKit`. No app target or
  gate depends on it. It runs one scenario per process, so the lifetime peak footprint belongs to
  that scenario, and every input is a deterministic RecortiaFixtures image. Two inputs: a 5120 × 2880
  text-dense interface screen (`SensitiveScreen`), like a Retina 5K capture, and a 3024 × 1964
  photographic chart.
- Metrics per scenario:
  - CPU time per iteration (`getrusage`, user + system), after one warm-up;
  - the encoded byte count for exports;
  - the peak physical footprint (`ri_lifetime_max_phys_footprint`).
- Wall time was recorded but is not used for decisions: the machine ran other agents' builds
  throughout, at load averages from 118 to 240.
- `run.py <label>` builds the harness in release, runs each scenario in several processes and
  reports the median of the per-process medians. Results go to the ignored `.scratch/perf/`.
- `ab.py <base-package> <head-package> <label>` builds two copies of the harness, one per tree, and
  alternates base and head processes inside every scenario, so load changes hit both sides alike.
  The final table below comes from it.
- A hypothesis is kept only when its target scenario improves by more than its process-to-process
  spread, every other scenario stays within spread, and its tests pass.

Scenarios:

| Scenario | What it times |
|---|---|
| `render_base_5k`, `_masked` | sanitized base render of the screen at 1×, without/with secure masks |
| `export_png_5k`, `export_auto_5k`, `export_heic_5k` | `ExportPipeline.snapshot` of the annotated, masked screen |
| `export_png_photo` | the same PNG export of the photographic chart |
| `decode_png_5k` | bounded import of a 5K PNG (container verification + decode) |
| `canvas_draw_5k` | one editor canvas draw of the annotated screen |
| `scan_sensitive_5k` | automatic masking's e-mail/phone scan of the screen |

## Decisions

| Id | Hypothesis | Verdict | Effect on its target (CPU median) |
|---|---|---|---|
| H1 | PNG Adler-32 verification is dominated by `Data.Iterator` and a per-byte modulo | kept, then replaced by H2 | decode 334.3 → 141.5 ms |
| H2 | Swift byte loops for CRC-32/Adler-32 still top the decode profile; use the system zlib's `crc32_z`/`adler32_z` | kept | decode 141.5 → 103.3 ms; PNG export 196.8 → 186.8 ms |
| H3 | ImageIO honours a PNG row-filter property for RGBA input | reverted | no byte change: ImageIO ignores the filter for RGBA (probe) |
| H3b | An opaque raster encoded without alpha honours the filter (None for interface pixels, Up otherwise) | superseded | −16.7% bytes, but +11.7% render CPU for the copy |
| H3c | A zero-copy `noneSkipLast` view after a word-wide alpha scan avoids that copy | superseded | −6.7% PNG CPU, but Automatic peak +54 MB (JPEG flatten redrew the view) |
| H3d | One opaque view shared by PNG, JPEG and HEIC; lossy encodes of an opaque canonical raster skip the compositing redraw | kept | PNG −11.5%, Automatic −13.1%; bytes −16.7% screens, −15.9% photos |

H2 keeps the test fixtures' own Swift CRC as an independent oracle. H3d's lossy path is held to
byte equality with the composited path by `opaqueLossyExportsMatchComposited`. A translucent
raster never takes the opaque view: one non-opaque alpha byte anywhere sends it down the existing
path.

## Final A/B (interleaved, 3 processes per side, 2 for the scan)

| Scenario | CPU base (ms) | CPU head (ms) | Δ CPU | Bytes base | Bytes head | Δ bytes | Peak base → head (MB) |
|---|---:|---:|---:|---:|---:|---:|---:|
| decode_png_5k | 313.58 | 88.89 | **−71.7%** | | | | 381.7 → 379.1 |
| export_png_5k | 175.23 | 158.17 | **−9.7%** | 1,962,159 | 1,633,708 | **−16.7%** | 276.1 → 273.3 |
| export_auto_5k | 252.08 | 216.70 | **−14.0%** | 1,962,159 | 1,633,708 | **−16.7%** | 286.6 → 282.8 |
| export_png_photo | 400.29 | 360.88 | **−9.8%** | 14,716,675 | 12,382,775 | **−15.9%** | 325.0 → 295.1 |
| export_heic_5k | 70.60 | 68.01 | −3.7% (spread 1.6) | 1,417,559 | 1,417,559 | 0% | 366.1 → 362.6 |
| render_base_5k | 9.61 | 10.03 | +4.4% (spread 0.8–1.1 ms, noise) | | | | 259.0 → 259.1 |
| render_base_5k_masked | 10.19 | 10.22 | +0.3% | | | | 259.1 → 259.2 |
| canvas_draw_5k | 14.08 | 14.18 | +0.7% | | | | 264.1 → 264.3 |
| scan_sensitive_5k | 4739.43 | 4733.20 | −0.1% | | | | 372.2 → 363.3 |

Load average at the end of the run: 161. The render and canvas deltas are smaller than their
process spread, and neither path changed on this branch.

## Not attempted

`scan_sensitive_5k` is the largest latency left (about 4.7 s of CPU for a 5K capture, and only
when automatic masking is on). It already scans tiles concurrently under bounded budgets. Nearly
all its time is Vision's accurate recognition across the three tile sweeps that the recall
contract in `SensitiveText.swift` documents. Fewer sweeps, larger tiles or `.fast`
recognition would each trade detection recall on a privacy control, so any of them needs the
owner's decision and a recall fixture set first.

## Reproduce

```sh
python3 -I docs/specs/performance-2026-11/run.py <label>
python3 -I docs/specs/performance-2026-11/ab.py <base-tree>/docs/specs/performance-2026-11/bench \
    docs/specs/performance-2026-11/bench <label>
```

For the base side, copy `bench/` to the same path in a worktree of the base commit. The harness
binds by relative path to the RecortiaKit of the tree it sits in.
