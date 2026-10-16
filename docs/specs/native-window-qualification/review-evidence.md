# Native window qualification evidence

Candidate base: `0781aedcbf4e743fd25b87b71356cbb5391aa86b`.
Environment: Xcode 27.0 (`27A266a`), Swift 6.4, macOS 27.2 seed host.
Current source candidate: 0.12.1/build20. Earlier BLOCKED observations below are historical;
the resumed graphical session now supplies the positive control. Final acceptance follows
the resumed evidence, not a reinterpretation of those failed runs.
All commands select `/Applications/Xcode_27.app/Contents/Developer` and
`RECORTIA_TOOLCHAIN_MODE=stable`. The installed 0.12.0/build19 remains unchanged.

## Research and independent review

The Fable plan advisor required matched position/opacity controls and separate observations
of key ownership, responder assignment, visibility and activation. It rejected treating a
green rerun as a causal diagnosis. The deep branch audit and Standards/Spec source reviews
reported no new confirmed defect outside native qualification; those were source reviews,
not runtime acceptance of all branch behavior.

Apple documents that ordering alone does not make a window key, and that cooperative
activation is distinct from ordering. The implementation therefore preserves inactive
presentation and tests cooperative activation only as a separate positive control.

- [Window ordering](https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless())
- [Key-window ownership](https://developer.apple.com/documentation/appkit/nswindow/makekey())
- [Cooperative activation](https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation)
- [Occlusion state](https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.property)

## Controlled diagnostics

Evidence root: `.scratch/native-window-review-20261015/`.

- `baseline-focused.log`: original focused native command, English capture-focus FAIL and
  editor-presentation PASS; Portuguese both PASS. Activation controls were skipped. This
  does not establish a deterministic product defect.
- `matrix-summary.json` and `matrix-*.log`: declared onscreen/offscreen × alpha0/alpha1
  matrix, production unchanged. All editor cases passed, including offscreen cases.
  Two offscreen English capture cases failed key ownership; onscreen cases passed.
  These results do not establish one cause for both historical failures.
- `host-ready.json`: disposable standalone normal-app prototype established foreground,
  key ownership, visibility and active-Space membership using ordinary launch, then quit.
- `owned-fixture-focused.log`: reusing the accessory E2E bundle as a helper failed all four
  startup controls. No scenario reached product behavior.
- `standalone-fixture-focused.log`: the separate normal-app target compiled and its generated
  plist reported `LSUIElement=false`. All four startup controls still failed: the owned
  window was visible and opaque but lacked key ownership, activation and foreground state.
  This remains a fixture failure, not a product diagnosis. No deadline was increased.

Focused command:

```sh
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=stable scripts/e2e.sh --lang all --only capture-focus,editor-presentation --unsigned
```

`standalone-fixture-lifecycle.log` records the next bounded English run after explicitly
selecting regular activation policy before the run loop and matching the prototype's screen
placement and window style. Both startup controls failed again, before product assertions.

`host-ready-recheck.json` repeats the previously successful minimal prototype using the same
ordinary `open -n -W -a` launch. It now reports `ready=false`, `active=false`, `key=false`,
`foregroundIsHost=false` and occlusion8192, with `visible=true` and `onActiveSpace=true`.
The prototype exits normally. The current graphical session therefore does not provide even
the known-good foreground control. These observations do not identify why activation was
declined, or prove that the helper implementation would pass in a suitable session.

Qualification is blocked pending a dedicated unlocked graphical desktop that can grant
ordinary activation to the owned synthetic control. No force activation, timeout increase,
TCC change, personal screen read or production focus change was attempted. The helper and
scenario changes remain an experimental candidate; final mutation controls, full gates and
final independent acceptance remain unrun. No new version, merge or release is justified.

## Preserved candidate and cleanup

The experimental source was committed and pushed on the existing draft working branch;
it changes only the test target and test scenarios, not production focus/presentation code.
Strict Swift formatting, `git diff --check`, the five E2E-isolation script controls and six
project-freshness script controls passed. Staged secret scans found no leaks. These checks
do not replace the blocked native behavior or final full gate.

All native reports were moved from the task worktree to
`.scratch/native-window-review-20261015/native-runs/`, retaining their timestamp/language
subdirectories. Original logs still contain their historical worktree paths. The committed
task worktree was removed, including approximately405 MB of its temporary build products;
the8.8 MB native evidence was preserved. No synthetic test process remained in the scoped
process check. Preexisting build caches, installed app/backup, archives and unrelated
`docs/handoffs/` were preserved. The visible branch remains `feat/onboarding-feature-guide`;
PR16 remains draft, with final acceptance pending.

The bounded follow-up Standards/Spec review of `0781aed..f6f8623` found zero confirmed
actionable defects in the experimental delta. It performed source review only. The reviewer
confirmed that missing readiness fails explicitly, cooperative activation is separate, and
production sources exclude the E2E helper. This does not qualify runtime behavior.
`complexity-candidate.json` covers exactly four Swift files/89 functions with zero parse
errors and empty stderr; coverage is partial and supplies no behavioral acceptance.

## Resumed graphical qualification

Evidence root: `.scratch/native-window-resume-20261015/`.

- `host-ready.json`: the same minimal normal-app control now reports active/key/foreground/
  visible/onActiveSpace/ready true, with occlusion8194. It exits automatically.
- Hosted stable CI38758599281 passed the exact earlier head643c04c. Its result did not waive
  native qualification and is not the later final-candidate CI.
- `focused-ready.log`, native run `20261015-161450`: capture-focus and editor-presentation
  pass in both languages, with two synthetic screenshots per language.
- `mutation-missing-key.log`, run `20261015-161512`: omitting only the required panel
  `makeKey()` call fails keyboard ownership and the dependent keyboard-transition assertions.
- `mutation-missing-ordering.log`, run `20261015-161558`: omitting only the editor's
  `orderFrontRegardless()` fallback fails the controlled overlap assertion: occlusion8192,
  active=false, key=false. The editor remains behind the known opaque cover.

Both production calls were restored exactly: `git diff --exit-code HEAD --
RecortiaApp/Capture/RegionOverlay.swift RecortiaApp/Editor/EditorWindowManager.swift` passed.
The correction is the test fixture/oracle, not a newly diagnosed production focus defect.
Version0.12.1/build20 and the regenerated project were committed before final gates.
The installed0.12.0/build19 executable still hashes to
`c4aecb8207593e0b80afc30a3312683644116a4fc963829600b4067c8556664b`.

Final `full-check.log` passed on executable source380a029:683 package tests,617 translated
strings, strict formatting/project freshness, app build and E2E-target build. No compiler
warnings or errors were found. `full-native.log` exited0 with47/47 scenarios,2222 assertions,
138 PNGs and zero skipped assertions per language (`20261015-161900`). Main inspected the
English selection overlay and both language editor-presentation renders.

Fresh different-model `mneves-verify` returned PASS for all ten frozen criteria. Its own
`20261015-162537` run passed3/3 scenarios and265 assertions per language, including the named
50-cycle overlay regression and editor reopening/cover/cooperative controls. It independently
inspected all four affected synthetic PNGs and verified the unchanged installed artifact.
The final receipt is in `acceptance-verdict.md`; exact-head CI remains the separate merge gate.

All runtime source, package configuration, project.yml and generated project are unchanged
since380a029; subsequent edits are documentation only. After evidence relocation, all current
native reports live under `.scratch/native-window-resume-20261015/native-runs/` with their
original timestamp/language subdirectories. The original logs retain historical worktree paths.

## 0.12.2 editor window size candidate (1b31c3f)

Editors now open at one remembered or default size (1100×720 pt) instead of each capture's size.
The full bilingual native run on 1b31c3f (`.scratch/e2e/20261016-083024-82851`, app-bundle SHA-256
`d2ac1a66…53259fd`, console unlocked and idle 128 s at start, two displays attached) passed 48/49
scenarios per language (2,263 EN and 2,260 PT-BR assertions). `editor-presentation` failed in
both languages, for two different reasons:

- EN: the cover reported containing the padded editor frame, but the negative visibility control
  (`!window.occlusionState.contains(.visible)`) did not settle.
- PT-BR: the owned foreground fixture, launched on the secondary display at (394, −1169), never
  became foreground (`owned foreground fixture state timed out for sequence 1`).

These failures are preserved. A rerun of the same app bundle in the same two-display layout
(`.scratch/e2e/20261016-084609-5369`, `--only editor-presentation --no-build`, idle 135 s) passed
31/31 assertions in each language. The comparison run on main without the size change was not
needed and did not run. This rerun does not qualify physical Spaces or the earlier failures.
Logs: `.scratch/editor-window-size-20261016/e2e-full-dfba173.log` (the run is on 1b31c3f; the
filename predates the last commits) and `e2e-ab-editor-presentation.log`.
