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
`.scratch/local-install-0.12.5-20261028/previous-0.12.4-23.app` — that directory was removed as
superseded on 2026-10-28 while the 0.12.7 build was installed, so the rollback target today is the
0.12.5 build 24 bundle kept at `.scratch/local-install-0.12.7-20261028/previous-0.12.5-24.app`.

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

## Closing sequence, 2026-10-28

- The `~/.agents` skill store: took the ffmpeg-skill 2.17.3 automated upstream release that the
  installer had left uncommitted, after the store's own gate (`validate --strict ok=True
  blocking=[]`, `parity to_create=0 problems=0`, `sync clean 55 / no-repo 2`); pushed as `0bd5ccb`.
- OptMem: the pending compression was already satisfied (`Nothing left to compress`).
- Version 0.12.6 build 25 is a documentation-only candidate: untagged, unnotarized, unpublished and
  not installed. The tag `v0.12.5-beta1` and the installed 0.12.5 build 24 are untouched.

## Deferred item taken, 2026-10-28

The performance finding the architecture review ranked first is done, measured as call counts:
`EditorModel.listItems` is memoised against `DocumentSession.revision`, so a selection change, a tool
change, a zoom or an in-flight draft no longer re-lay out every text annotation. Planted revert fails
the new test with three issues. Not done, and why: the AX messaging timeout needs a fixture that can
simulate a hung peer before it can have a test; the retained-pixel budget needs a memory measurement
on a stable host; the editor menu commands need physical keyboard qualification.

## Local installation, 0.12.7 build 26, 2026-10-28

Installed the build the memo fix ships in, from a detached worktree at `889f67a`, with the profile
recovered earlier and the same export settings. Nine checks before touching `/Applications`: strict
signature and Designated Requirement, 0.12.7 build 26, Hardened Runtime, embedded profile, the exact
entitlement set with the Keychain access group, no `get-task-allow`, no test-only markers in 43
Mach-O files, `spctl` accepting it as Developer ID, and a byte-identical installed bundle
(33 files, 60 entries, no symlinks, sha256 `3efed410…`).

0.12.7 launches and runs with a clean startup log. The previous 0.12.5 build 24 is preserved under
`.scratch/local-install-0.12.7-20261028/previous-0.12.5-24.app`. Nothing was running before the
replacement, so no session was discarded.

No version bump: the repository is already at 0.12.7 build 26, which is exactly what was installed.
Moving the number again would ship an identical binary under a new one and force the CHANGELOG to
describe a release with no change.

## Cleanup mistake, 2026-10-28

I moved `.scratch/local-install-0.12.5-20261028` into a staging directory and let `scratch clean`
delete it. The BACKLOG and progress entries cited a bundle *inside* that directory, so the citation
guard did not see it: it checks the entry it is given, not paths nested under it. The 0.12.4 build 23
bundle is gone; the 0.12.5 build 24 bundle it installed survives in the 0.12.7 directory and is now
the rollback target. Both records are corrected to say what exists instead of what used to.

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

## Source candidate 0.14.0 build 28, 2026-11-11

Branch `feat/editor-redesign`. Documentation and version only; no Swift changed.

- `project.yml` moved to 0.14.0 build 28 and `xcodegen generate` rewrote only the two version
  settings in both configurations (`bf5c0a1`).
- CHANGELOG `[0.14.0]` is written as a source candidate; the `[Unreleased]` agent-instructions entry
  moved into it. BACKLOG gains `source_candidate_0_14_0`; `current_candidate` and
  `current_local_installation` stay on the published 0.13.0, as `2858cf1` left them for the 0.13.0
  candidate. README describes the new editor, Settings and appearance; its version, install and
  download lines still name 0.13.0. AGENTS.md and CLAUDE.md record the new invariants.
- `SPEC.md`, `ACCEPTANCE_TESTS.md` and `docs/architecture/module-contracts.md` were searched and left
  unchanged: no sentence had become false, and every public name in the contracts is still public.
- Gate: `.scratch/logs/release-prep-check.log`, `./init.sh check --unsigned` at `896bce7`, ends
  `check: all gates passed`; 530 package tests (105 + 126 + 261 + 38), 620 pt-BR strings.
  `tests.json` did not need regenerating.
- Not a clean E2E pass: `.scratch/logs/final-e2e.log` (at `4f8ec58`) is 52/54 en and 53/54 pt-BR,
  with `capture-focus` failing in both languages (en at the owned foreground fixture, pt-BR at its
  foreground and keyboard-ownership assertions) and one `ocr-qr` foreground check in en; the session
  recorded the Mac as in use during the run. The full
  bilingual run on the final tree, on an idle unlocked console, is still pending.
- Not tagged, notarized, published or installed.

## Release 0.14.0 build 28, 2026-11-11

- Three independent verifier passes found V-1 (scrolling review had no dark check), V-2
  (`last-window` pressed through a click that needs a key window) and V-3 (saved-color tooltips
  differed from the spec); each was fixed with a red control (`findings.md`).
- Security audit of the final tree: no confirmed vulnerability; gate WAIVED for SEC-11, SEC-17 and
  SEC-18 until 2026-11-25; independent acceptance PASS, including a full native E2E of 54/54 per
  language on an idle, unlocked console.
- PR #40 squash-merged as `cdffc96` (tree equal to the verified head), tagged `v0.14.0`,
  `scripts/release.sh` exit 0, notarized, published, public download byte-identical, installed in
  `/Applications`. Details: `docs/specs/editor-redesign/release-0.14.0.md`.

## 2026-11-21 — T6 native qualification and A-5

- The cumulative T6 native suite on `c5bd784` reported 68/73 in each language. The same five
  scenarios failed. The original native reports and provenance are in E2E run
  `20261121-113721-19677`. PRs #43–#47 record the scope and outcomes of that cumulative evidence.
- Draft #47 contains `c2dc828`, which passed the clean local unsigned gate (1,082 package tests)
  and the hosted Debug and Release checks. Its focused native rerun was void when the console
  resumed input. No outcomes from that rerun qualify the candidate.
- The current T6 head `8d1ed31` follows AppKit's cooperative activation contract. It passed
  the unsigned E2E target build with stable Xcode 27.2 (27B52), a fresh read-only review and the
  exact-head [hosted Debug and Release checks](https://github.com/mneves75/recortia/actions/runs/44922689305).
  An uninterrupted native rerun is pending. Opus cross-model review hit its usage limit.
- A-5 proceeds in an isolated worktree with live region selection as the default and an explicit
  freeze action for one display during selection. Its crop and magnifier use the same frame.
- A-5 commit `74b64b7` passed all six `RegionPrecisionCaptureTests` cases, including the
  negative-origin crop and late acquisition after cancel or unfreeze. It is superseded by the
  pending review fixes. Independent review found that the crop could retain the full frame
  during registration, a freeze command could be dropped while a canceled read drained, and
  the native magnifier assertion needed a source-pixel comparison. The older plan's pixel
  coordinates and sleep/timeout cleanup also remain required.
- A-5 checkpoint `d119e78` resolves the review findings, adds pixel coordinates and clears
  capture state on system/display sleep. Both unsigned Debug targets compiled. The focused
  package test covered seven cases, all 115 targeted redaction/privacy tests passed, and all
  781 extracted strings had pt-BR translations. The planted aliased-image control failed at
  the source-frame release assertion while registration was suspended. The restored suite
  passed again. A separate model re-reviewed the changes and cleared the three findings.
- A-5 expires a freeze after 60 seconds of monotonic time, measured from the request. The
  deadline is checked when a display read returns and before a frozen region can be committed.
  Permission loss or a changed display still ends selection when it coincides with expiry.
  The focused suite passed eight tests, including timer-first and callback-first permission loss.
  Bilingual native execution needs an unlocked console with a five-minute idle start and no
  input until the run finishes. The affected macOS 26 physical checks remain open.
- The repository generates `tests.json` as its test inventory and
  `.scratch/tests-report.json` as the run-status record via `scripts/tests-report.py`.
  New test code is limited to behavior over the requested `cccc` complexity threshold or
  regular-expression behavior. Pruning and independent verification follow implementation.
- The uninterrupted bilingual focused run `20261121-165623-55160` on `bf1c4a5` passed
  `capture-precision` and `pin-on-top` in both languages. `editor-menu`, `colour-tools`,
  `framing-presets` and `heic-and-print` failed in both languages. The console monitor
  recorded no interruption. The native run log is `.scratch/logs/e2e-bf1c4a5-qualified-focused.log`.
- The four scenarios now wait for the native menu state, read selectable text through its
  accessibility value, or bring the newly captured editor forward before clicking Reset.
  The Inspector submenu still has both tab commands disabled while another window is key.
  The preview test checks both transitions and both native checkmarks.
- The uninterrupted focused replay `20261121-170244-80788` on `cb634be` passed five of six in
  each language. The menu, framing reset and print corrections passed. Both formatted text
  readouts also passed, exposing the next assertion in `colour-tools`: the four Pass/Fail marks
  are static text and the scenario had been querying their accessible names. The next replay
  reads their values and still checks each localized verdict exactly.
- On `812a68c`, `colour-tools` passed in both languages in `20261121-170801-10350`.
  The following full run `20261121-170832-15352` was void after console input and was stopped.
  The focused report completed before the console interruption.
- With owner approval, removed the duplicate `RegionPrecisionCaptureTests.remembersAspect` case.
  `capture-precision` exercised the same 16:9 control, read the saved preference, and verified
  the next selection inherited it in both languages in `20261121-170244-80788`.
  `RegionPrecisionTests.aspectPreference` still checks fresh and legacy defaults and persisted
  round-trip equality. The pre-pruning unsigned baseline ran 1,086 package tests.
- The unsigned gate passed all 1,085 package tests and both Debug targets on clean `a68231a`
  in `.scratch/logs/check-a68231a-retry.log`. An earlier run on the same commit failed only on
  the Imaging cancellation test's 10-second elapsed limit during heavy host load. The isolated
  test passed in 0.25 seconds, and the unchanged gate passed on the retry.
- Independent review strengthened two existing assertions. `capture-precision` now checks the
  settings store independently of the coordinator, so a ratio cached only in the coordinator
  cannot satisfy it. `editor-menu` still checks the Inspector submenu is reachable when an editor
  is key, in addition to checking both tab commands are disabled without a key editor.
- Clean `5cc56ce` passed 1,085 package tests and both Debug targets on Xcode 27.2 (27B52).
  Its qualified onboarding replay reproduced the same preference change in both languages.
  Diagnostic commit `a338d64` isolated the change to `showsMenuBarIconChoice`, while the separate
  upload consent identity and side-effect checks passed. The menu-bar visibility setter now
  ignores requests that match the effective visibility, preserving the default choice on replay.
- `fc540b1` passed all nine focused native scenarios in both languages. Its uninterrupted full
  run `20261121-194710-31503` passed 72 of 73 per language, with only the diagnostics directory
  assertion failing. Foundation resolved the existing test parent from `/private/tmp` to `/tmp`
  while preserving the spelling of its missing child. The assertion now verifies the exact
  child of the resolved parent and rejects a symlink. Temporary controls accepted the intended
  missing child and rejected a similarly prefixed sibling and two kinds of symlink.
- Clean `2d1b6df` passed the local unsigned gate (1,085 tests and both Debug builds), hosted
  CI and the focused bilingual diagnostics replay. The full English replay
  `20261121-210130-89670` then passed 68 of 73. In the cold-launch import control, the 20-second
  wait ended as the 11th read was still admitted. The four later import-dependent scenarios
  reported busy. The preceding qualified bilingual run passed these five scenarios. The
  Portuguese part of this full attempt is void after console input.
- Cold-launch replay now returns the handle of the admitted batch. The existing scenario
  awaits its completion before checking all 12 native editor titles in order, once-only reads
  and no refusals. The runner's existing watchdog bounds a hung batch. A fresh independent
  source review confirmed the startup counter and asynchronous dispatch remain in their
  original positions. Bilingual replay is pending.

## 2026-11-21 — Expand the current quick capture preview

- Created `feat/quick-capture-preview` from `5cc56ce`. The approved roadmap, preview spec and
  first three tickets are committed separately as `08b23a1`. The release draft remains on
  `5cc56ce`, whose local unsigned gate ran 1,085 package tests and whose hosted checks passed.
- Preview uses the existing masked renderer, with a bounded output and one in-memory render slot.
  The native scenario is extended instead of adding small isolated unit tests. It exercises
  nonactivating presentation, Escape, suspension, replacement and light/dark rendering.
- The initial unsigned Debug E2E app compiled with Xcode 27.2 (27B52). An independent source
  review found presentation ordering races around capture suspension and a masked-pixel control
  that could pass on a blank image. Both findings require correction before final verification.
- Corrected those races. A thumbnail that finishes during selection waits for cancellation or
  replacement, and an expanded render without a visible panel is cleared on suspension.
  RED-01 now verifies that the same native path displays different unmasked pixels. A second
  source review approved the fixes. The rebuilt unsigned E2E app and the warm focused command
  `xcrun swift test --jobs 2 --package-path Packages/RecortiaKit --filter 'QuickActionsModelTests|PinnedExportTests'`
  passed 17 tests. Swift formatting, diff validation and the 13 extracted panel string
  translations passed.
- The first release preflight expired. The next native run of `5cc56ce` started after five idle
  minutes. The independently scoped preview still needs full, native and physical qualification.
- The full local unsigned gate on `4662cc6` passed all 1,085 package tests and built both Debug
  targets. GitHub Actions run 44956086618 passed the unsigned and Release isolation checks.
- The uninterrupted native Quick Actions replay `20261121-201311-48883` reproduced an image
  cropped to the preview frame and both panels remaining visible at selection start in EN and
  pt-BR. The screenshot chrome check sampled no pixels. Focus assertions after Escape also
  failed without identifying whether the frontmost app or the key panel changed.
- The native image view now reports its display size explicitly. Capture suspension looks up
  Recortia's visible windows on the active Space in window-server order, including panels.
  The existing Quick Actions scenario requires both panels to hide before testing restoration
  and reports separate foreground and key-window flags right after closing. The corrected
  unsigned E2E app compiled with Xcode 27.2 (27B52). Its native replay is pending.
- The local unsigned gate on clean `ca5593b` passed 1,085 package tests, both Debug builds,
  localization, and the app launch guard. Independent review found that the broader enumeration
  could also include modal alerts. Capture suspension now adds only the owned Quick Actions
  windows, using the window server's order for those two panels.
- The full A-5 attempt on `2d1b6df` stopped after the login screen took the foreground.
  That attempt is void. GitHub's exact-head checks passed for A-5. The qualification launcher
  now checks the kernel lock field directly and rejects the login screen in its foreground check.
- On clean `269ee56`, both unsigned Debug targets compiled and hosted CI passed the unsigned
  and Release isolation checks. The uninterrupted bilingual run `20261121-205717-66634`
  passed window presence, other Spaces, capture focus and recapture. Quick Actions proved
  the full preview image, light and dark chrome, both panels hidden for capture, restoration on
  cancel, and the first Escape's closure. The owned app stayed frontmost after deliberate
  keyboard focus. The test had also expected the runner's activation flag to stay false and
  tried to make the owned app's window key while the thumbnail held key focus. Independent
  review approved separating those checks. Both Escape routes now require the expected key
  panel and the owned foreground process immediately before Escape, without reassigning key
  focus in the dispatch helper. The second Escape and subsequent RED assertions need replay.
- The independent source verification of the comparison plan passed. Native acceptance
  combines the ten preview, capture and import scenarios on the branch with `309a550` included.
- Clean `7b84230` passed 1,085 package tests, both Debug builds, and the bilingual native runs
  `20261122-005232-79090` (10/10 each) and `20261122-005502-91505` (73/73 each). The Developer ID
  dry run also completed. Independent review found that a 320×100 capture on a 2× display could
  shrink from a 240×75 pt thumbnail to a 160×50 pt preview. Preview now magnifies small rasters
  for inspection within the same display bounds. The renderer's raster keeps its existing size
  limits. Requalification of the sizing correction is pending.

## 2026-11-22 — Qualified native replay and local 0.15.0 installation

- On clean `6ac344b`, GitHub Actions run 44989058389 passed the unsigned gate and Release
  isolation check on matching source tree `ed68094`. Local Xcode 27.2 (27B52), macOS 27.3
  (26C5047e), passed `RegionPrecisionCaptureTests` (7 tests, including resumed and stalled
  expiry at 60 seconds and permission loss). The cold-launch fixture delivered both six-file
  requests once, in order, with no refusals.
- Interrupted and timed-out attempts contributed no qualification. The uninterrupted retry passed
  11/11 focused and 73/73 full scenarios in each language, with 576 and 5,661 assertions per
  language respectively. Evidence in the `feat/quick-capture-preview` qualification worktree:
  `.scratch/logs/e2e-6ac344b-qualified-full.log`, native runs
  `20261122-125852-63870` and `20261122-130236-98961`. Independent visual review measured the
  larger preview fixture at 1280×840 pixels versus 480×315 in the thumbnail. The small-capture
  enlargement has source verification and still needs physical observation.
- A source comparison found the old dynamic probe activated before ordering and used the
  new-pin path for an existing pin. The corrected cooperative probe passed all four
  fresh/reused window and pin cases with zero Space switches, preserving the fullscreen host.
  The host retained foreground ownership. The forced comparison recorded one switch for a
  reused ordinary window and one for the policy-free control. Console input invalidated that
  comparison. Both logs are in the same qualification worktree:
  `.scratch/logs/space-order-cooperative-6ac344b-20261122-133257.log` and
  `.scratch/logs/space-order-compare-6ac344b-20261122-132914.log`. The installed app's
  physical fullscreen behavior remains open.
- Installed the exact Developer ID export, 0.15.0 (29), at `/Applications/Recortia.app`.
  Independent verification matched 177 bundle entries, strict signing, Hardened Runtime,
  provisioning profile, Keychain entitlement and macOS execution policy. The existing 0.14.0
  process continued with the original PID and mapped executable inode. Its bundle remains intact
  in the primary main checkout at `.scratch/install-0.15.0-20261122/Recortia.app`; the same
  directory has `installation.json`.
  Build 29 awaits its first launch. The public distribution assessment requires a notarization
  ticket.
- Preliminary release review leaves SEC-11, SEC-17 and SEC-18 open for this candidate.
  The bundle omits the updater key. Keep Sparkle inactive and reassess the current
  [package-update advisory](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-gcjm-h3jh-p2vc)
  before enabling updates. Main, public download and release tag remain at their prior version.
