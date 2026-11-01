# Candidate validation — 0.13.0 (27)

Status: **scoped implementation and independent behavior acceptance PASS**, 2026-11-01.
Published as v0.13.0 at `2858cf1` (notarized; public download byte-identical to the qualified DMG);
the production export is installed locally (PASS). See [release-0.13.0.md](release-0.13.0.md).
No physical capture qualification is implied. The sections below are the acceptance history.

## Behavior delivered

Settings › Export reuses the existing sanitized still-capture export and bookmark. Choose,
replace, cancel and remove work through native controls; removing the folder disables automatic
saving. Unavailable destinations remain selected and show a warning. Pending saves recheck consent
and destination before writing. Imports, scrolling reviews and later edits retain explicit saving.

Settings › General persists whether Recortia keeps running after its last ordinary window closes,
defaulting on without resetting older sealed preferences. Opting out requests normal termination
after export results. Other/minimized/pin windows and active capture protect the session; launch,
hiding and panel closure alone never quit. Unsaved-edit cancellation remains guarded. Accepted
capture startup cancels an earlier pending quit synchronously, including same-turn cancellation.

## Environment and source checks

macOS 27.2 (26B123), Xcode 27.2 (27B52), Swift 6.4.2, SDK 27.2 (26B118), deployment target macOS 15.0.
The stable toolchain was checked against Apple's [official release record](https://developer.apple.com/news/releases/).
No global toolchain or system permission setting changed.

| Check actually run | Result | Evidence |
| --- | --- | --- |
| Signed `scripts/check.sh` on production source `3d2dba7` | PASS, exit 0; 519 package tests, script controls, format, project freshness, 629 translations and both Debug targets | `.scratch/autosave-menu-bar/parent-check-resume-signed.log` |
| Full `scripts/e2e.sh --lang all` on clean `3d2dba7` | PASS, exit 0; 52/52 scenarios and 142 screenshots in each language | `.scratch/e2e/20261101-143019-66053/` |
| Latest installed stable Xcode MCP BuildProject | PASS, 17.739 s; zero warnings; SettingsView, AppModel and AppPresence refreshed with zero diagnostics | `.scratch/autosave-menu-bar/xcode-resume-build.log`, `xcode-resume-diagnostics.json` |
| Expanded native revocation/hide/panel probes | PASS, exit 0; 2/2 scenarios in each language | `.scratch/e2e/20261101-151010-12523/` |
| Fresh independent complete native reverify with expanded probes | PASS, exit 0; 5/5 in each language, six screenshots each | `.scratch/e2e/20261101-151339-27864/` |
| Fresh independent isolated SettingsStore/Integrity operator | PASS, exit 0; 11/11 tests | `.scratch/autosave-menu-bar/verify-opus-flows-final.md` |
| Fresh Spec and Standards axes on resumed code and final test delta | Zero P0–P3 findings | Independent review records; no GUI run claimed by reviewers |
| `cccc --no-cache --min 0` on both final scenario files | PASS, 2/2 files, 85 functions, zero parse errors; maxima cognitive 13/cyclomatic 16 | `.scratch/autosave-menu-bar/complete-probes-complexity.json` |

Commands use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and
`RECORTIA_TOOLCHAIN_MODE=stable`. The independent native operator was:

```sh
scripts/e2e.sh --lang all --only last-window,automatic-save-settings,quit-confirmation,automatic-export,stale-folder
```

The first expanded gate stopped at two LineLength lint failures; Opus wrapped only those
assertions and focused strict lint then passed. The original failure remains in
`parent-check-complete-probes.log`. Final all-source and whole-suite confirmation logs use
`parent-check-final-signed.log` and `parent-e2e-final-all.log` in the same private directory;
their actual exit status belongs to the final delivery record.

## Independent acceptance and controls

Fresh Sol, source-blind, verified every Opus-built clause (1, 2, 3, 4a, 5, 6): PASS after one
correction round added direct runtime probes for pending file-consent revocation and hide/panel-only
lifecycle. Both languages exercised actual native Settings input, real isolated defaults, local
file writes and native child-process exits. The verifier decoded all six output PNGs, checked CRCs
and scanlines at 1280×840, and preserved all 120 collision sentinels. It inspected General,
long-folder and unavailable-folder renders. Report: `verify-opus-flows-final.md`.

Fresh Opus, source-blind, separately verified the Sol-built pending-quit correction (4b): PASS.
Removing only synchronous capture-start invalidation in a disposable worktree caused the same-turn
case to fail with five termination requests instead of four; the fixed binary passed 89/89 checks.
The ordinary export/file-before-quit and report-before-quit controls passed on both binaries.
The initial mutant readiness failure was unqualified; its unchanged retry supplied the decisive
failure. Report: `verify-late-capture-result.md`; hashes, reports and provenance are retained under
`nonce-control-evidence/`. The task-owned mutant worktree was removed after evidence preservation.

The initial locked-session verifier was BLOCKED, not PASS. Resumed native RED then reproduced a
real missing-folder-warning defect with Settings genuinely foreground; Opus corrected transient
availability refresh. Existing accessibility Press assertions stay strict; pointer delivery uses
the runner's event queue and the selected pane. Historical failures and their logs remain intact.
A mismatched-provenance `--no-build` attempt correctly stopped before launch; a standard rebuild
established matching provenance without bypassing the guard.

`autoreview --max-priority P3` could not launch `codex-auto` in its isolated HOME because the Profile
Manager dependency was unavailable. Fresh independent Spec/Standards reviews provided the skill's
capability fallback. No launcher or global configuration was modified.

## Distribution and remaining limits

The c981e74 dry-run archive/export under `.build/release/0.13.0-dev-20261101T052043Z-17174/`
is retained as history and superseded: it excludes the folder-status refresh and must not be
installed. It passed strict signature, parsed entitlements, profile, Hardened Runtime, license and
eight artifact contract controls; its manifest says no tag, internal gate skipped and no
notarization.

The released artifact was built from the tag at `2858cf1` by the full `scripts/release.sh`
pipeline, with its own exact-commit security verdict (WAIVED SEC-17, SEC-18). Its identities,
notarization, download check and local installation are in
[release-0.13.0.md](release-0.13.0.md). Security records remain private.

Native evidence uses the separate DEBUG E2E app and synthetic frames, upload/clipboard sinks and
folder/confirmation boundaries. It does not qualify real NSOpenPanel interaction, personal preference
relaunch, live ScreenCaptureKit/TCC, physical Spaces/displays, IME or VoiceOver. No personal screen
content, credentials or system settings were read or changed for these tests.
