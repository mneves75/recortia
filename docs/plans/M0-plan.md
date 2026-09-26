# M0 plan — feasibility and approved plan

**Status:** Proposed, awaiting owner approval. FP-001 (read-only inventory) is complete; FP-002 and
FP-003 have not started.
**Date:** 2026-09-26 · **Tasks:** FP-001, FP-002, FP-003 · **Requirements:** FR-01, FR-02, FR-06,
FR-10, FR-14

This plan answers START_HERE.md. Everything under "Verified" was observed with the command shown.
Anything else is labeled an assumption or a hypothesis for a spike to test.

## 1. Verified facts (FP-001)

### Repository

| Fact | Evidence |
|---|---|
| Documentation-only bundle: no Xcode project, Swift package, scripts, tests, or CI | `git ls-files` at `451f734` |
| Own git repository on `main`; private remote `mneves75/recortia`, pushed over SSH | `gh repo view --json visibility` → `PRIVATE` |
| `MANIFEST.sha256` was removed outside the agent session before import | Its 12 hashes all passed with `shasum -a 256 -c` before removal |
| PRs are squash-only; head branches are deleted after merge; Dependabot alerts and security fixes are on | `gh api repos/mneves75/recortia` read back |
| Rulesets, branch protection, and secret scanning are unavailable for this private repo | API returned 403 "Upgrade to GitHub Pro…" and 422 "Secret scanning is not available" |
| Five triage labels exist | `gh label list` |

### Toolchain and host

| Fact | Command |
|---|---|
| Stable Xcode 27.0 (27A266a), macOS SDK 27.0 (26A425) | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version`; `xcrun --show-sdk-build-version` |
| Swift 6.4 (swiftlang-6.4.0.34.1), the same compiler in both Xcodes | `xcrun swift --version` |
| **`xcode-select` points to Xcode-beta 27.2 (27B5019j)** | `xcode-select -p` |
| **Host OS macOS 27.2 (26B5091g) is a seed build** | `sw_vers`; SoftwareUpdate `CatalogURL` contains `index-27seed` |
| Mac17,9, Apple M5 Pro, 64 GB, one built-in 3024×1964 Retina display, **no external display** | `system_profiler SPHardwareDataType SPDisplaysDataType` |
| Required APIs are available at the macOS 15.0 target | Typecheck probe plus a negative control; see ADR-001 |
| KeyboardShortcuts 3.1.0 → `772133d9…` (MIT); Sparkle 2.10.0 → `eef1a539…` | `gh api …/git/ref/tags/…` |

### Assumptions (not verified)

- SCK still capture behaves on macOS 15.0 and 26 as it does on the 27.0 SDK headers. There is no
  15 or 26 host to run it on.
- A macOS VM on this Mac can serve as a stable-OS host and support ScreenCaptureKit. Untested.
- Whether GitHub counts included Actions minutes against macOS runners at a multiplier isn't stated
  on the billing page read. Its per-minute rates are $0.062 for macOS and $0.006 for Linux 2-core.

## 2. Checks this environment cannot run yet

| Check | Blocker | What unblocks it |
|---|---|---|
| GEO-01 mixed-DPI matrix (1x plus 2x, negative origins, rotation, unplug) | One built-in display | An external 1x display. Virtual displays need a private API, which is forbidden. |
| PERF-01 budgets | Seed-OS host (SPEC §10 requires a stable OS) | A stable macOS 27 host or VM |
| Support on macOS 15 and 26 | No such host | VMs or other Macs running those versions |
| PERM-01 with a real denial and first prompt | Needs a clean test user and your presence | Decision D2 |
| REL-02 signing and notarization | No Developer ID or team ID; out of M0 scope | FP-015 |

## 3. Decisions needed from the owner

| # | Decision | Recommendation |
|---|---|---|
| D1 | Approve M0 execution: FP-002 and FP-003 code spikes in this repo | Approve. The spikes are disposable and synthetic-only. |
| D2 | Live-capture consent for FP-002: a dedicated macOS test user, where only the spike's synthetic fixture window is on screen and you grant or deny Screen Recording yourself | Create a `recortia-test` standard user. The agent never touches the TCC database or your own session's screen. |
| D3 | Stable-OS and legacy-OS test hosts | Plan macOS VMs (15, 26, stable 27) before FP-007. The seed host is fine for compiling and unit tests. |
| D4 | External display for GEO-01 | Borrow or buy any 1080p (1x) monitor before FP-007 closes, or record GEO-01 as blocked. |
| D5 | GitHub plan | Stay on Free until FP-004 adds CI. Then choose between GitHub Pro (branch protection and required checks on a private repo) and making the repo public, which the SPEC's open-source goal points to. |
| D6 | Bundle identifier and final name | Needed at FP-004. "Recortia" is unverified as a brand (SPEC header). |
| D7 | License | MIT is proposed (SPEC §2). No LICENSE file is committed while the repo is private and unapproved. |

## 4. Proposed files

M0 adds only spikes, fixtures, reports, and ADRs. No RecortiaApp code is written before FP-004.

```text
Spikes/CaptureSpike/                 FP-002, disposable (deleted or archived after FP-007)
  CaptureSpike.xcodeproj             minimal app bundle (see §5.1 for why not a CLI)
  CaptureSpike/App.swift             window with a numbered-corner checkerboard fixture
  CaptureSpike/Probe.swift           SCK still capture, geometry log, exclusion check
Spikes/PrivacyScrollSpike/           FP-003, SwiftPM, headless
  Package.swift                      swift-tools-version 6.2, macOS 15, Swift 6 mode
  Sources/FixtureGen/                deterministic secret-region pairs and scroll pages (seeded)
  Sources/SpikeRender/               mask → resample → PNG encode → decode (the spike pipeline)
  Sources/SpikeMatch/                multi-strip overlap matcher with consensus
  Tests/RedactionSpikeTests/         RED-01 metamorphic test plus planted-leak controls
  Tests/ScrollSpikeTests/            SCR-01 success and SCR-02 rejection cases
Fixtures/README.md                   provenance schema (generator, seed, license, scale, color space, size)
docs/adr/0002-permission-and-sandbox-profile.md   FP-002
docs/spikes/FP-002-capture.md        observations, commands, raw logs (no real screen content)
docs/spikes/FP-003-privacy-scroll.md results, failures, what did not run
```

The fixture generator is kept separate from the render code on purpose. A test that builds its
expected output with the code under test only proves the code agrees with itself.

## 5. Spike designs

### 5.1 FP-002 — capture, geometry, permission (needs D1 and D2)

1. **Build the spike as an app bundle, not a command-line tool.** TCC credits Screen Recording to the
   process responsible for the request. A SwiftPM executable started from Terminal or an agent would
   be credited to that host, which confounds PERM-01. The spike gets its own bundle ID and an ad-hoc
   signature.
2. The fixture window draws a checkerboard with numbered corners and one-pixel border lines.
3. Capture the display once with the spike's own windows excluded (`SCContentFilter` excluding the
   spike app). Assert the checkerboard is absent. Then capture that window directly and compare its
   corners and edges pixel-for-pixel with the drawn fixture.
4. Record `pointPixelScale`, `contentRect`, the output `CGImage` width and height, and the display's
   `NSScreen.backingScaleFactor`. Derive point-to-pixel mappings from these, never from a
   hard-coded 2x.
5. Permission states on the test user: preflight false → request → deny → import still works (a mock
   stands in for import in the spike) → grant in System Settings by hand → capture works. Record every
   `SCStreamError` code observed.
6. **Sandbox investigation for ADR-002:** build a second, sandboxed configuration of the same spike.
   - Hypothesis H1: SCK still capture works sandboxed once Screen Recording is granted.
   - Hypothesis H2: `AXUIElement` scroll actions against Safari are unavailable to a sandboxed app.
   Both are tested, not assumed. If H2 holds and H1 holds, ADR-002 compares two options: a
   sandboxed core with automatic scrolling deferred, or the SPEC's non-sandboxed single target.

Evidence: exact commands, OS build, per-display numbers, pass/fail per step. Images are fixture-only
and are committed only if synthetic.

### 5.2 FP-003 — privacy rendering and scroll matching (needs D1 only; runs headless here)

**RED-01 prototype.** For seeds 1…N, `FixtureGen` produces pairs A and B that are identical outside a
secret rectangle, with text in A and noise in B. The spike pipeline masks the source, resamples at
0.5×, 1×, and 2× with high-quality interpolation, encodes PNG, and decodes it again. The test requires
byte-identical decoded buffers, including at fractional mask edges, and metadata identical under an
allowlist.

**Planted-violation controls** (these must fail, proving the test can detect leaks):

- C1: mask applied after resampling in output space with truncating rounding. The resampling kernel
  pulls secret pixels across the edge.
- C2: blur applied before the mask.
- C3: a translucent overlay (alpha 0.99) instead of an opaque fill.

If any control passes, the test is broken, and FP-011 cannot rely on it.

**Scroll matcher prototype.** `FixtureGen` renders a long synthetic page with a fixed seed, including
a fixed header and footer band. It slices viewport frames with bounded random offsets and adds ±1
noise. The matcher estimates vertical displacement independently in at least three overlap strips
and accepts a frame only when they agree.

- Success case: textured page reconstructs with an exact row sequence, no missing or duplicated rows.
- Rejection cases: a page of identical repeated rows, and a frame with less overlap than the minimum.
  Both must be reported as ambiguous or rejected, never as a stitched success.

## 6. Benchmark endpoints (defined now, measured in FP-023)

`OSSignposter` intervals, named once in FP-004 and never renamed:

| Interval | Start | End | SPEC §10 target |
|---|---|---|---|
| `capture.overlay` | shortcut handler entry | first overlay frame | p95 ≤ 100 ms |
| `capture.commit` | selection commit | first full-resolution editor frame | p95 ≤ 300 ms |
| `app.launch` | process start | menu bar item ready | p95 ≤ 1.5 s |
| `ocr.recognize` | request issued | result accepted on the main actor | p95 ≤ 1.5 s |

These results are recorded only from a stable-OS host (D3).

## 7. Risks

| Risk | Effect | Mitigation |
|---|---|---|
| Builds silently use the beta Xcode | Evidence produced by a disallowed toolchain | `DEVELOPER_DIR` in every command; FP-004 doctor script fails on a mismatch |
| No 1x display | GEO-01 cannot close, and 0.1 cannot ship | D4 |
| Sandbox tradeoff decided without evidence | Wrong security posture baked in | FP-002 step 6 tests H1 and H2 |
| No server-side protection or secret scanning | A force-push or a leaked key goes unnoticed | D5; `.gitignore` excludes key material; review diffs |
| macOS CI minutes on a private repo | Budget runs out once FP-004 adds CI | D5; run Domain tests (no AppKit) cheaply, and keep macOS jobs small |
| RED test turns out to be vacuous | False redaction assurance, the highest-severity threat | FP-003 planted controls C1–C3 must fail |

## 8. Smallest useful vertical slice (M1)

**Open PNG → bounded decode → preview window.** It needs no permission and is testable headless:

- It exercises the Domain → Imaging → MacPlatform boundary, IO-01 limits, and the String Catalog.
- It works whatever D2 decides.

Still capture (FP-007) follows it, reusing geometry measured in FP-002.

## 9. M0 verification commands

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -version        # must print Xcode 27.0 / Build version 27A266a
swift test --package-path Spikes/PrivacyScrollSpike
xcodebuild -project Spikes/CaptureSpike/CaptureSpike.xcodeproj -scheme CaptureSpike \
  -configuration Debug -destination 'platform=macOS' build
```

The `CaptureSpike` run itself is manual, on the test user (D2). None of these commands exist until
D1 is approved.

## 10. Exit criteria for M0

- FP-002: still-capture results, window-exclusion result, geometry numbers, GEO-01 either run or
  recorded as a hardware block, and ADR-002 accepted by the owner.
- FP-003: RED-01 prototype passes and all three planted controls fail; one stitch succeeds and one
  ambiguous stitch is rejected; the report lists anything that did not run.
- BACKLOG.json statuses reflect evidence, not effort.
