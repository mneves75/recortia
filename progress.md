# Progress — 0.12.5 instrumented review

Branch `chore/toolchain-27.2-and-release-review`. Each line points at the evidence, not at a
feeling. Spec: `docs/specs/release-review-0.12.5/spec.md`.

## 2026-10-28

- Read the tree, `git status` clean at `3d52b80`, no worktrees, no `.scratch`.
- Found every gate blocked: `doctor.sh` rejected Xcode 27.2 (27B48) against a record that still said
  27.1 (27A9275). Apple publishes 27B48 as the Xcode 27.2 RC (2026-10-19), `/Applications/Xcode.app`
  verifies as com.apple.dt.Xcode signed by Apple and `spctl` accepts it. Recorded as the development
  toolchain; stable qualification stays blocked because 27.0 (27A266a) is no longer installed.
- Gate 1 green after that: `.scratch/logs/check-2.log` ends `check: all gates passed`, 617 pt-BR
  strings, both Debug targets.
- Installed BAMA (20 of 21 skills) into `~/.agents/skills`, linked into all 11 agent roots that
  `skillctl` manages. `skillctl parity` went 140 to create, then 0. `research` was skipped: it
  collides with the installed `research` skill and BAMA's version is for pre-build market research.
- Three read-only reviews (design/accessibility, architecture/performance, test quality). Findings
  were treated as leads: every one in the spec was re-read at its line by me first.
- Instruments added and each proved to fail on a revert:
  - isolation scanner: `NSPasteboard(name: .general)` and `UserDefaults(suiteName:)` rules with
    planted controls. Revert control: removing either rule makes
    `test_scan_flags_every_planted_violation` fail (records: `CONTROL-1/2 -> False`).
  - defaults-domain guard: reads executable lines only. Control: a commented-out guard with a real
    fallback makes the guard test fail (`CONTROL-3 -> False`).
  - `scripts/tests-report.py --check`: fails when a gate's test is missing, when a `scripts/test-*.py`
    is named by no gate, and when a caller never invokes its test. Five planted tests.
  - `tests.json`: generated, never hand-edited. A log without a terminal verdict is reported
    `incomplete`/`running`, never `passed` or `failed`.
  - E2E watchdog: a hang is silence, not elapsed time. The old 300 s per-language ceiling killed a
    progressing run (`e2e[en]: no report (exit 143 ... after 300s)`, last PASS `export-sinks`).
    Measured: `ocr-qr` alone takes 76 s, `text-decorations` 51 s.
  - appearance axis: `E2ESnapshot.park/host` take an appearance parameter (default unchanged), and
    `appearance-contrast` renders the scroll review twice with and without seams and measures the
    pixels that changed.
- Plant for the appearance axis: reverting the seam markers to `Color.primary` produced
  `strongest 1.08:1` (dark page, light appearance) and `1.06:1` (light page, dark appearance), so the
  scenario failed. Details in `docs/specs/release-review-0.12.5/plants.md`.
- Fixed in the same pass: dead pin accessibility label, seam-marker contrast, save-folder row,
  destructive credential removal behind a confirmation, closable review window whose close, Escape
  and Discard all ask once.
- Removed a duplicate entitlements test and a two-of-three-unreachable parameter table.

## Adversarial review of the diff

Two fresh-context reviewers read the diff and the spec. Both found real defects in my own work;
all are now closed or corrected, none silently dropped:

- the discard checks proved a closure was called, not that the window's close is answered. The
  review window is now controller-owned, takes its own delegate, and the scenario asserts the
  delegate identity. Planted revert fails it (`the controller is the window's delegate: nil`).
- `onDiscard` defaulted to a direct `model.discard()`, the silent path the decision removed. It is
  no longer a parameter.
- the seam measurement counted a per-pixel share, so a mark over 10% of the width scored 1.0, and it
  took the brightest pixel anywhere instead of a per-band floor. It now requires one horizontal band
  per seam spanning at least 80% of the preview, and the 3:1 floor applies to every band. A portrait
  fixture had been hiding the second seam behind the review's viewport.
- the markers leaned on `Color.accentColor`, which leaves 3.75:1 on a light page with the default
  blue and would fall under the floor with a graphite or yellow accent. They are a black-and-white
  keyline now: measured 19.17:1 on dark, 19.60:1 on light and 5.32:1 on mid grey, accent-independent.
- the watchdog measured silence in a log written only after each scenario. The runner now logs
  `START <id>` before each scenario, and the stop walks the process tree.
- `tests.json` could be stale and still pass `--check`. It now compares the recorded inventory and
  statuses with the evidence on disk, and the last terminal marker wins. It caught its own staleness
  during the gate.
- `DoctorTests` still hardcoded the development pins. They now come from the record.

Two acceptance criteria in the spec promised proofs this repository cannot produce. Both are
corrected in the spec's amendments section rather than claimed: a hosted SwiftUI view exposes an
empty in-process accessibility tree (measured on 2026-10-28), and there is no layout instrument for
a rendered row height.

## Independent verification

A fresh-context verifier ran the frozen criteria. A1 (BAMA installed and linked in all 11 roots,
`parity to_create=0 problems=0`), A2 (every fix supported at its line), A3 (every instrument can
fail), A5, A6 (no new tag, no release, no cask change) and A7 passed. A4 was **BLOCKED**: that agent
had no shell, so the gate and E2E were not executed by it. Their real results here are
`.scratch/logs/check-9.log` and `.scratch/logs/e2e-final2.log`, and CI on the pull request ran the
same gate independently.

The verifier's notes were acted on rather than argued with: the accent-dependent marker (3.75:1 on a
light page with the default blue, below the floor with graphite or yellow) is now a black-and-white
keyline at 19.17:1 / 19.60:1 / 5.32:1; the contrast floor is per band, not the brightest pixel
anywhere; and four doc sentences that overstated what was measured are corrected.

## Local installation, 2026-10-28

The owner asked to deploy on this Mac. The documented path was blocked twice over: `release.sh`
requires the stable 27.0 toolchain, which is not installed, and the `Recortia Developer ID`
provisioning profile was no longer in the profile store. The profile was recovered from the
embedded profile of the installed 0.12.4 bundle (UUID `c9bdcdae-…`, expires 2044) and reinstalled
locally; nothing touched the developer portal.

Archived from a detached worktree at `e071be1`, exported as `developer-id` with manual signing, then
verified before installation: strict signature and Designated Requirement, version 0.12.5 build 24,
Hardened Runtime, embedded profile, exact entitlement set with the Keychain access group, no
`get-task-allow`, no test-only markers across 82 Mach-O files, and `spctl` accepting the bundle with
`source=Developer ID`. The installed bundle is byte-identical to the export (33 files, 60 entries, no
symlinks); the previous 0.12.4 bundle is preserved under
`.scratch/local-install-0.12.5-20261028/previous-0.12.4-23.app`.

0.12.5 is running. The 0.12.4 process had terminated normally at 02:11:38, before the bundle was
replaced, and left no crash report. Not verified, because the console was locked throughout:
notarization, clean-user launch, TCC prompts, physical keyboard, Spaces, VoiceOver and any GUI
inspection.

## Skills collection review, 2026-10-28

The owner asked for a review of `~/dev/Skills` (Dimillian's Skills, 29 skills) and for anything that
applies to be applied here. The audit ran; nothing was applied blindly, and the reason is recorded
per skill in `docs/specs/release-review-0.12.5/xcode-security-settings.md`.

- `audit-xcode-security-settings`: the C/C++/ObjC half does not apply — this repository has no C,
  C++, or Objective-C sources (checked), and the skill's own reference forbids enabling clang-only
  settings for pure Swift. The one capability that would apply, Enhanced Security, changes the
  shipped binary's architecture, its entitlement set and the runtime OS requirement at once, so it is
  deferred with the exact conditions an adoption must meet rather than slipped into a tagged
  candidate.
- `modernize-tests`: nothing to do; no source file imports XCTest.
- `swiftui-view-refactor`: two files named as the worthwhile candidates (1030 and 925 lines); a split
  is a refactor with its own spec.
- The rest either duplicate work already done this session (review swarms, concurrency, performance)
  or target stacks this app does not use (Tuist, SwiftPM packaging, iOS simulator, React, App Store).

## Results

- Gate: `.scratch/logs/check-8.log` ends `check: all gates passed`.
- Bilingual E2E: `.scratch/logs/e2e-2.log` and `.scratch/logs/e2e-final.log`, 50/50 scenarios per
  language, 138 screenshots each, on the code before the keyline and per-band changes. The recorded
  state before this work was 45/47 per language.
- Bilingual E2E while the console was locked: `.scratch/logs/e2e-final2.log`, 48/50 per language.
  Both failures were `capture-focus` and `editor-presentation` on the foreground-fixture readiness
  control (`key`, `active`, `foreground` false, `unoccluded` false) with `IOConsoleLocked=Yes`.
  A locked console voids GUI qualification, so it was reported as an environmental block, not a
  pass, and it was not explained away.
- After the console was unlocked, both scenarios passed in both languages
  (`./init.sh e2e --only capture-focus,editor-presentation --lang all`), and the full suite passed
  **50/50 per language at `4d3dcf1`**: `.scratch/logs/e2e-final3.log`, 138 screenshots each. The
  locked-console reading was right, and it is now proven rather than assumed.
- Those two scenarios are also the pair the repository recorded as failing before this work
  (`TOOLCHAIN.json`, `installed_stable_observation.native_e2e`).
- `tests.json` regenerated from that evidence and checked by `scripts/tests-report.py --check`.
- 0.12.5 build 24 is a source candidate: not tagged, notarized, published or installed.
