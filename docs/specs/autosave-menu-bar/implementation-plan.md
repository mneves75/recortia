# Automatic-save configuration and last-window preference

Status: source 0.13.0 build 27; signed local gate passed; final native E2E and crossed review blocked.
Owner request: 2026-10-31. Current evidence: [validation.md](validation.md).
Requirements: FR-01, FR-07, FR-14; new work unit FP-044 (next unused ID after FP-043).

## Assumptions and scope

- Automatic saving means the existing still-capture export, before subsequent editing. Imports,
  scrolling reviews and later edits keep their existing explicit-save behavior.
- Save to a folder selected in Settings, only after explicit opt-in. Preserve configured users.
- Keep running in the menu bar is a separate General preference, enabled by default to preserve
  current behavior. Disabling it affects closing the final ordinary window, not application launch.
- Explicit Quit always follows existing unsaved-edit confirmation. A canceled close never quits.
- Native macOS Settings remain the design system, with English and pt-BR localizations.
- No additional cloud destinations, screenshot archive, background capture, dependencies or TCC changes.

## Current evidence

`origin/main` and clean `main` both resolved to `6690ec9e03d52bb372629987ae4967614adb62b9` after fetch.
Existing Settings already offer automatic save and a remembered folder; ExportCoordinator already
rechecks consent and destination before writing through ShareSnapshot. MenuBarExtra already remains
available after all windows close. The change should expose the requested control and remove invalid
folder/opt-in combinations, rather than build a second exporter or window-presence manager.

Host preflight: macOS 27.2 (26B123), Xcode 27.2 (27B52), Swift 6.4.2, macOS SDK 27.2.
Apple's releases page lists Xcode 27.2 (27B52), 2026-10-29, and macOS 27.2 (26B123), 2026-10-26:
https://developer.apple.com/news/releases/ . At preflight, TOOLCHAIN.json recorded an earlier RC and the old
stable baseline. The reviewed record now uses the verified stable installation; retain deployment
target macOS 15.0, Swift 6 language mode and release safeguards. No global toolchain change.
Xcode MCP opened the real project and baseline BuildProject succeeded (34.486 seconds, no errors).

## Decisions and alternatives

1. Reuse the existing automatic-export pipeline and folder bookmark. Improve the Settings controls
   to choose a destination when enabling without a valid folder, leave state unchanged on cancel,
   display unavailable destinations, and permit clearing a destination while disabling autosave.
   Rejected: a new background autosave/history service; it changes privacy and document semantics.
2. Extend AppPresence's existing coalesced window/hold ownership. Adversarial planning found that
   a bare AppKit last-window hook cannot account for active capture holds and asynchronous export
   batches. Trigger only after an actual switchable-window close; never from launch, minimize,
   hiding or panel closure. Wait for both an export operation and its automatic batch to finish.
   Rejected: a bare applicationShouldTerminateAfterLastWindowClosed hook and a parallel manager.
3. Prefer an optional stored Bool with effective default true, so synthesized Codable can preserve
   previous blobs without a handwritten decoder duplicating every preference. A required synthesized
   Bool is unsafe because its initializer default is ignored by Codable. Never drop unrelated
   consent, export settings or sealed preferences on upgrade.

## Frozen acceptance and verification seams

1. Settings allow choosing, replacing and clearing an automatic-save folder. Cancel is a no-op.
   Empty/unavailable/invalid bookmark cannot silently enable saving or cause fallback elsewhere.
2. Opt-in still capture writes a decodable image into exactly that folder. Off writes nothing;
   repeated names do not overwrite existing files. Preference/folder revocation before commit
   prevents a write. Preserve existing RED, cancellation and consent tests.
3. General exposes a localized, persisted keep-running preference. Existing preference blobs load
   without resetting settings and default to today's keep-running behavior.
4. Enabled: closing the final editor/Settings/pin leaves the process and menu usable, with accessory
   activation. Disabled: closing the last real user window requests normal termination, while another
   editor, Settings, minimized window, pin or active capture prevents premature termination.
   Launching without a window and capture-panel closure alone never quit the app.
5. Unsaved-edit cancel preserves the editor and process. Explicit Quit remains available in both modes.
6. Exercise the real native Settings controls and actual close lifecycle with isolated synthetic data
   in English and pt-BR; inspect exported bytes and rendered Settings, including a long folder name.

## Execution

1. Read applicable instructions, existing callers/tests/ADRs and Apple SDK declarations.
2. Record adversarial plan review; resolve risks within these acceptance criteria.
3. Implement one red/green vertical slice at a time through native Settings and export/lifecycle seams.
   Retain original failing evidence; do not weaken tests. Use existing E2E isolation and synthetic sinks.
4. Update the toolchain record from primary Apple evidence and actual SDK observations; run doctor
   regressions, formatting/project freshness, package tests and both app builds with scripts/check.sh.
5. Run scripts/e2e.sh --lang all and inspect native Settings renders; fix actual failures.
6. Run independent code-review axes and adversarial review against the frozen starting commit, plus
   requested Xcode MCP build/diagnostics. Then mneves-verify in a fresh context with a different model.
7. Bump to 0.13.0 build 27 in project.yml, regenerate project, and update relevant product, acceptance,
   backlog and agent docs. Never hand-edit tests.json. Recheck after changes.
8. Commit task-owned paths and push the working branch; skip staging and GitHub CI as requested.
   Merge only verified changes to main, then remove the task branch without rewriting history.
9. Run mneves-security deploy gate for the final tree before distribution/local installation. Reuse
   waivers only after proving exact owner/reason/expiry/target scope. Archive/export Developer ID,
   verify entitlements/signatures, preserve previous installed bundle, and install/relaunch on this Mac
   as authorized. Public release/tag/notarization use scripts/release.sh only when its gates pass.
10. Clean only disposable resources created by this task; retain security gate evidence and report
    synthetic tests, local installation and public release separately. Never claim physical/TCC proof.

## Five-year maintenance check

Keep one owner for export consent, one for app presence, native controls and explicit failure paths.
Avoid timers, raw-pixel exports, secondary save pipelines and premature schema frameworks. The
durable result is behavioral regressions at those boundaries, rather than additional abstractions.

## Plan challenge (fresh planning context)

The independent planner confirmed the AppPresence and optional-preference decisions above. Its
additional acceptance case requires actual process exit in a native child, rather than only
asserting a callback; capture holds, minimized windows and same-turn replacements remain controls.
`scripts/doctor.sh` failed before implementation with the expected exact Xcode-baseline mismatch;
the original output is retained in `.scratch/autosave-menu-bar/baseline-doctor.log` (exit 1).
The hosted CI runner still names `/Applications/Xcode_27.app`; CI is explicitly skipped by the
owner for this task, so local qualification is reported separately and no hosted runner is changed
without evidence of what is installed there.

Execution note: the parent is rerunning doctor controls outside the restricted shell sandbox in
`.scratch/autosave-menu-bar/parent-test-doctor.log`. Restricted `pgrep`/`ps` failures are environment
blocks, not product defects: do not weaken or broaden process cleanup to make them pass. Never use
`pkill -f` or a process-name pattern; stop only exact task-owned PIDs whose ownership was checked.
SECURITY.md and the incident-procedure paragraph in THREAT_MODEL.md are parent-owned changes from
the independent security audit; preserve them when committing the feature.
The parent doctor run passed all 16 controls (exit 0, 72.814 s); the live stable doctor also passed.
The verified toolchain unit is committed/pushed as `3bf2bf4` on the working branch (no CI run).
SwiftPM's nested manifest sandbox is also blocked in the restricted worker shell. The parent
attempted a normal-permission RED compile, but it waited for the worker's SwiftPM lock and was
interrupted after the worker began implementation; `parent-red-1-package-compile.log` is therefore
unqualified diagnostic evidence. The worker's `red-1-package-compile.log` did reach the compiler
and failed because `QuitAfterLastWindow` was not implemented. Do not count sandbox_apply/manifest
failures as behavioral RED. Parent and worker builds remain sequential from this point onward.

## Implementation record (worker, 2026-11-01)

Decisions taken while building, beyond the plan above:

- Quitting waits on `ExportCoordinator.isBusy` and on `AppModel`'s count of automatic exports from
  scheduling until their result is reported, instead of reading `automaticBatch` directly. Only
  `AppModel` starts automatic batches, so the count spans every batch and also the moment before
  its task starts; because it ends after reporting, a failure alert is shown before the quit.
  `isBusy` keeps its meaning for the editor. After the late-capture correction,
  `QuitAfterLastWindow` first cancels the quit for the keep-running preference or an active
  capture, then waits for exports, then considers remaining windows. An export's failure alert
  does not cancel its result-reporting wait.
- `AppPresence` reports a close in the refresh that sees it or never: a capture hold present then
  drops it. A shortcut pressed right after the last close, then cancelled, leaves Recortia in the
  menu bar, which keeps "closing a capture panel never quits" true.
- `SettingsStore.sanitized` turns automatic saving off without a chosen folder. An older blob that
  had it on without a folder (it failed on every capture) loads with it off. The export
  coordinator test that covered the missing-folder failure now covers a chosen folder that no
  longer resolves, which keeps the same failure branch and assertion.
- The folder panel and termination are `AppModel` initializer parameters (defaults `NSOpenPanel`
  and `NSApp.terminate`), so E2E replaces both and never opens a panel or quits the runner.
- `TOOLCHAIN.json` records 27B52 as both the stable baseline and the observation, with no release
  candidate. `scripts/test-doctor.py` derives a fixture candidate from the stable pin when none is
  recorded; `scripts/test-release-contract.py` now reads the pin from the record instead of copying
  27.0 (27A266a), which failed five of its controls after the record update.

Worker environment: `xcodebuild` could not resolve packages (writes to
`~/Library/Caches/org.swift.swiftpm` denied), so `scripts/check.sh`, `check-localization.py` and
`scripts/e2e.sh --lang all` were not run by the worker and `last-window` and
`automatic-save-settings` have not executed yet. App sources were type-checked with `swiftc` against
the rebuilt package modules (`.scratch/autosave-menu-bar/typecheck-app.sh`), with and without
`RECORTIA_E2E`. Pasteboard and QR-render package tests fail in that shell at the base commit too
(`.scratch/autosave-menu-bar/base-env-failures.log`).

Known risks for the first native run: `accessibilityPerformPress` on SwiftUI toggles in Settings
(earlier scenarios press buttons), the pin panel counting as switchable in the child probe (the
probe exits 3 if not), and `NSApp.terminate` exiting 0 through the delegate's unexported-edit
check. If a toggle press fails, fix `E2EAccessibilityControl.press`, not the assertion.

## Parent qualification and adversarial findings (2026-11-01)

- Latest installed stable Xcode MCP compiled the candidate successfully (11.65 s). Its refreshed
  diagnostics for AppModel, AppPresence and SettingsView contained zero diagnostics. Build log:
  `/var/folders/x_/ll566vlj2q72ssm7jsrt66f00000gn/T/ActionArtifacts/default/BuildProject/BuildProject-Log-20261101-012829.txt`.
- Focused native runs are retained as failing witnesses, not final acceptance:
  `.scratch/e2e/20261101-011010-13047/`, `20261101-011908-95563/` and
  `20261101-013106-64035/`. The second run passed `last-window` in both languages, including
  actual child-process exit. Automatic-save checks decoded the first real output and preserved
  colliding files, but later Settings interactions failed. The third run reproduced that failure.
- Instrument diagnostics showed that Settings was hidden and not key both before and after the
  capture. The fixture must establish a visible, active, key synthetic window before interacting;
  changing event routes alone did not establish the missing readiness control.
- Quartz session metadata then confirmed `CGSSessionScreenIsLocked: true`. Native interaction
  qualification requires the owner to unlock the Mac. No lock, permission or TCC setting is changed.
- Independent Spec review found that a capture beginning during an export wait could leave an
  earlier quit decision alive. Add a late-capture regression, including immediate cancellation,
  observe RED, then cancel the decision synchronously at accepted capture startup. Retain the
  export-result reporting guard. This correction remains within FR-01.
- Opus implementation reached its weekly quota. A bounded Sol fallback is preparing only the
  readiness fixture and RED assertions; production correction and crossed review remain separate.
- After the weekly reset, Opus remained unavailable due its five-hour quota (until 03:10 local).
  The authorized Sol fallback corrected only the capture decision precedence and synchronously
  invalidated pending quit at accepted capture startup. Parent observed the genuine policy RED
  (exit 1) in `parent-red-late-capture.log`, then all 44 focused tests passed (exit 0) in
  `parent-green-focused.log`, including isolated UserDefaults persistence. The ready-window
  fixture and late/same-turn native regressions remain unrun while the Mac is locked; neither
  these green package tests nor the earlier child-process pass completes native acceptance.
  Crossed review of the Sol delta remains required when Opus is available.
- Final signed `scripts/check.sh` passed on `45a92e4`: 519 package tests, script controls,
  formatting, project freshness, 629 translated strings, production and E2E target builds.
  Final Xcode MCP build of the corrected source passed in 3.962 seconds, with zero warnings
  and zero refreshed diagnostics in AppModel, AppPresence and SettingsView.
- The corrected fixture was exercised in both languages in
  `.scratch/e2e/20261101-021325-10346/`. All four scenario/language cases stopped at their
  readiness control: visible window, no key/active state, foreground PID 451 (`loginwindow`).
  A fresh source-blind verifier independently confirmed the locked session. No clicks or
  screenshots qualified. Its `mneves-verify` verdict is BLOCKED, not a product failure or PASS.
