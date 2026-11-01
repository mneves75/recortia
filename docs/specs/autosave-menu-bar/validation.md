# Candidate validation — 0.13.0 (27)

Status: **current full gate and independent behavior verification pending**, 2026-11-01.
Initial code qualification was at `45a92e4`; resumed native checks found and corrected a folder
status refresh defect. Focused flows now pass in EN and pt-BR as recorded below. Historical
gate/export evidence does not qualify the newer code. Installed 0.12.7 (26) and published 0.12.4
remain unchanged.

## Delivered source

Settings › Export reuses the existing still-capture export and folder bookmark: choose, replace,
cancel, remove and report unavailable destinations. Clearing disables automatic saving. Later
edits, imports and scrolling reviews retain explicit-save behavior.

Settings › General persists whether Recortia keeps running after its last ordinary window closes,
defaulting on without resetting older sealed preferences. The opt-out requests normal termination
and waits for export results. Accepted capture startup cancels a pending quit synchronously.

## Checks actually run

Environment: macOS 27.2 (26B123), Xcode 27.2 (27B52), Swift 6.4.2, SDK 27.2 (26B118).
Deployment target remains macOS 15.0. Apple lists this stable Xcode build in its
[official release record](https://developer.apple.com/news/releases/).

| Check | Result | Evidence |
| --- | --- | --- |
| Late-capture policy regression before correction | RED, exit 1, one behavioral issue | `.scratch/autosave-menu-bar/parent-red-late-capture.log` |
| Focused settings/export/lifecycle tests after correction | PASS, exit 0, 44 tests including isolated UserDefaults | `parent-green-focused.log` in the same directory |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=stable scripts/check.sh` | PASS, exit 0; 519 package tests, script controls, format, project freshness, 629 translations, both signed Debug targets | `parent-check-signed.log` |
| Latest installed Xcode MCP `BuildProject` after correction | PASS, 3.962 s; zero errors/warnings | `xcode-final-build.log`, `xcode-final-diagnostics.json` |
| Xcode MCP refreshed AppModel, AppPresence, SettingsView | PASS, zero diagnostics | `xcode-final-diagnostics.json` |
| Native focused EN and pt-BR, final fixture | BLOCKED; process exit 1 from failed readiness | `.scratch/e2e/20261101-021325-10346/` |
| `scripts/release.sh --dry-run` on c981e74 | PASS, exit 0; Developer ID archive/export and signed DMG prepared | `parent-release-dry-run.log` |
| Release contract with exported app and pinned package checkout | PASS, eight tests, no skips | `parent-release-contract-artifact-2.log` |

The latest focused command was:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=stable \
  scripts/e2e.sh --lang all --only automatic-save-settings,last-window
```

Both scenarios in both languages stopped before any input: window visible, but not key or active,
with `loginwindow` (PID 451) foreground. A fresh source-blind verifier independently confirmed
`CGSSessionScreenIsLocked=True`. No screenshots qualified. The earlier run that decoded a saved
image and preserved collisions, and the earlier bilingual child-process exit pass, are retained
in `.scratch/e2e/20261101-011908-95563/`; they do not qualify the final fixture.

## Prepared local artifact

This retained earlier artifact is superseded: it excludes the resumed folder-status refresh fix.
A fresh Developer ID export is required before installing the latest candidate.

`.build/release/0.13.0-dev-20261101T052043Z-17174/` contains the retained archive, exported app,
signed DMG and `manifest.txt`, built from a fresh checkout of `c981e74`. The export passed strict
signature, Hardened Runtime, reviewed entitlement/profile, version/build, license and no-test-marker
checks. The embedded Developer ID profile matches the reviewed team/app identity, expires
2044-09-21 and carries no `get-task-allow`. The actual app's Keychain entitlement passed the
existing parsed-plist gate. DMG SHA-256:
`11c8cb1ce5592045a9e0f9f6de6b9169dd041e5cd5b0b09edeef3e310dd0c24e`.

The dry-run manifest explicitly says `gate: skipped (dry run)`, `tag: none`, `notarized: 0`.
The independently recorded signed local gate is separate. This is a prepared artifact, not an
installation or public release; the temporary archive worktree was removed by the pipeline.

## Resumed checks

- Real native RED, including after Settings regained foreground:
  `.scratch/e2e/20261101-141218-38267/` failed only the missing unavailable-folder warning while
  file failure/no-fallback checks and both language lifecycle scenarios passed.
- Native pt-BR GREEN: `.scratch/e2e/20261101-141656-83183/pt-BR/`, 2/2 flows.
- Native EN GREEN on the same unchanged binary: `.scratch/e2e/20261101-141946-13966/en/`, 2/2.
  The first EN attempt stopped before input at host readiness; the original failure is retained.
- Current pointer input uses the runner's FIFO event queue and selected-pane geometry. Existing
  accessibility Press assertions remain strict. Activation requires actual foreground ownership;
  the owned host is never replaced silently by another PID.
- Transient folder availability refreshes on appearance, bookmark changes and app key-window
  events. Consent is preserved; no watcher, timer or new export pipeline exists.
- Fresh crossed reviews of the new Opus delta: Standards zero P0–P3 findings; Spec zero P0–P3.
  The earlier Sol lifecycle correction separately passed Opus review; its two P3 test findings
  were addressed. Full-suite and fresh independent behavior qualification remain pending.

## Independent review and remaining gates

- **Spec axis:** one P2: a late capture could leave pending quit alive during export. Genuine
  unit RED/GREEN is retained; the late and immediate-cancel native regressions now pass in both
  focused language runs. Crossed Opus review accepted the Sol lifecycle correction.
- **Standards axis:** zero findings in the original Opus portions. Opus identified two P3 test
  issues in the Sol delta; strict AXPress and selected-pane pointer checks address them. Fresh
  Sol Standards/Spec reviews found zero P0–P3 findings in the resumed five-file Opus correction.
- `autoreview --max-priority P3` could not launch the required `codex-auto` in its isolated HOME
  because its Profile Manager dependency was absent. A fresh independent Standards review was
  used as the skill's capability fallback; no launcher/configuration was modified.
- **mneves-verify:** the initial locked-session report was BLOCKED. Fresh behavior verification
  remains pending after the resumed fixes. Initial private report:
  `.scratch/autosave-menu-bar/verify-behavior.md`.
- Production security still needs candidate-specific resolution of SEC-17, SEC-18 and independent
  acceptance. Historical release waivers are not reused. Security records stay private under
  `.scratch/security-gate/` and are distinct from product acceptance.

Next: run the current full signed gate and full bilingual native gate, finish fresh independent
verification, then qualify a new Developer ID export, installation and the public notarized release.
No merge, tag, installation or release was performed. Staging and GitHub CI were skipped
as requested; this native app has no staging resources to disable.
