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
  scenario failed. With the dual stroke, all four combinations pass at or above 3:1 with at least
  15% pixel coverage.
- Fixed in the same pass: dead pin accessibility label, seam-marker contrast, save-folder row,
  destructive credential removal behind a confirmation, closable review window whose close, Escape
  and Discard all ask once.
- Removed a duplicate entitlements test and a two-of-three-unreachable parameter table.

## Open at the time of writing

- Full bilingual E2E after the changes.
- Adversarial review of the diff, then `mneves-verify`.
- Version bump, docs, commit, push, merge, cleanup.
