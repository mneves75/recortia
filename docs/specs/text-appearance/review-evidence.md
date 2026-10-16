# Text appearance: ticket01 evidence

## Scope and current verdict

FR-05 / FP-033 ticket01 implements three system-font designs. Ticket02's four decorated
appearances have not begun. This is source work for 0.12.0/build19, not an installation or
complete reference-product parity claim. Full repository gate and fresh independent
code/native acceptance are pending at this checkpoint.

## Test-first implementation

The backend worker recorded red/green model, export, geometry, undo-style synchronization,
empty-text legacy and invalid-text error regressions. Detailed commands and focused results:
`.scratch/text-font-designs-20261014/backend-evidence.md`. Initial full package run passed
Domain60, Features295 and MacPlatform134; Imaging150 had one broad-AppKit-import guard failure.
The subsequent narrow font import exception passed focused verification. That earlier full
run remains FAIL; focused success does not retroactively change it.

Native source-red commands used
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development scripts/e2e.sh --lang en --only <scenario> --unsigned`:

- `.scratch/text-font-native-red.log`: missing Rounded control.
- `.scratch/text-font-native-reopen-red.log`: rounded document/export reopened in a standard
  native font. The shared resolver now supplies NSTextView's font.
- `.scratch/text-font-native-wrap-red.log`: native container ignored content maxWidth.
  Native sizing now retains that constraint through zoom and confirmation.
- `.scratch/text-font-native-frame-and-failure-red.log`: finite-overflow text failed after
  a valid rectangle, leaving its partial canvas pixels. The App now clears drawing before
  posting the existing preview-failure notice.

The first radio-group selector was visible but AX Press and fresh AX-frame window events did
not change its binding. Explicit native choice buttons replaced it; no test-only style mutation
substitutes for the control action. The experimental helper flag was removed.

## Native evidence

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development scripts/e2e.sh --lang all --only text-font-designs,text-layout-failure --unsigned`
passed at `.scratch/e2e/20261014-170125/{en,pt-BR}/report.json`: 4/4 scenario executions,
220 assertions, eight rendered images. Log: `.scratch/text-font-native-complete.log`.
Main inspected the Portuguese minimum-size dark layout and English failure layout. Controls
and selected checkmarks are readable at 980×560; the failure clears the canvas and displays
the existing error notice. Tests also exercise native insertion, reopen/cancel/confirm,
all three design controls, selected AX values, new-text default, Unicode, wrapping and zoom.

This predates the final tour sentence update. The later gate/native judge must check that
candidate again. No personal pixels, real TCC settings, global clipboard or upload are used.
Programmatic Unicode insertion is not physical IME/VoiceOver qualification.

## Reviewed font boundary and measurements

A fresh read-only adversarial reviewer configured as gpt-6-astra/high approved only the exact
NSFont/NSFontDescriptor class imports in Sources/Imaging/TextLayout.swift. Controls reject
broad/other/duplicate/malformed imports, semicolons, newline/comment variants, wrong paths
and forbidden calls after valid imports or URL strings. Four additional controls requested
by the reviewer passed (`font-boundary-controls.log`). This scanner is an accidental-regression
guard, not a capability sandbox. Configured model identities are not runtime-attested.

`cccc` 1.8.0 ran from the repository root with existing policy, `--no-cache --min 0`, over 27
explicit changed Swift files (21 package, six App/E2E). Output:
`.scratch/text-font-complexity.json`, stderr `.scratch/text-font-complexity.stderr`; exit0,
27 files / 776 functions. RenderEngine.swift reports a syntax parse error at line58, so metrics
are partial and cannot qualify that file. No policy/cache/config changed. A dynamically
assembled invocation was rejected by the host's command guard; the explicit literal-path
invocation succeeded. Complexity scores do not replace code review or tests.

## Environment and limits

Local macOS27.2/26B5112a arm64; Xcode27.1 RC/27A9275, SDK27.0, Swift6.4, deployment macOS15.
An Xcode-beta diagnostic request could not target Recortia: the bridge listed only an unrelated
workspace. That workspace was left untouched. Stable release qualification, physical
IME/VoiceOver/Spaces, signing, installation and notarization remain unrun for this slice.
The historical full Portuguese capture-focus failure and skipped activation positive controls
are separate unresolved qualification evidence; this work does not waive them.

No worktrees, watchers, dependency installs or shared-cache cleanup were created. Small test
artifacts remain as cited evidence. The preexisting untracked docs/handoffs directory is preserved.

## First full gate and review corrections

Commit e72816d passed
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development scripts/check.sh --unsigned`:
639 package tests (134 MacPlatform / 150 Imaging / 295 Features / 60 Domain), 596 app strings,
two unsigned Debug builds, doctor/isolation/format/project checks. Log:
`.scratch/text-font-ticket01-check.log`. This is development qualification on the RC toolchain.

The two fresh Matt Pocock review axes were configured as gpt-6.1-sol/xhigh:

- Standards: one P2 documented breach. Layout/font admission caught an error and returned
  false, but the native button discarded that result, leaving no visible refusal. The
  possible scattered-selection-synchronization smell was a judgement, not a hard standard.
- Spec: one P2 defect. Select All bypassed text-style loading for a sole text annotation,
  leaving an incorrect selected-style indicator. The spec axis did not classify the notice
  issue as its own confirmed spec defect. Neither axis executed tests or native actions.

Both findings were reproduced before correction: `.scratch/text-font-refusal-notice-red.log`
failed on a nil notice; `.scratch/text-font-select-all-red.log` failed on stale appearance and
size. The first now posts the existing preview notice before refusing, while keeping admission
ahead of document/history mutations. Select All now uses the existing setSelection boundary.
`.scratch/text-font-review-corrections-green.log` passed all eight model tests.

The corrected native run included the updated tour and a real canvas Cmd+A key-equivalent
check of the selected AX value:
`scripts/e2e.sh --lang all --only text-font-designs,text-layout-failure,onboarding --unsigned`
with the same explicit development environment passed six scenario executions and 34 images
at `.scratch/e2e/20261014-175412/{en,pt-BR}/report.json`. Log:
`.scratch/text-font-review-corrected-native.log`. Full corrected gate and independent
source/behavior verdicts remain pending at this checkpoint.

Correction metrics use the same cccc1.8.0 policy and flags: four explicitly named changed
Swift files, 145 functions, zero parse errors; output `.scratch/text-font-correction-complexity.json`
and `.stderr`, exit0. The earlier 27-file metrics retain their RenderEngine parse limitation.

## Corrected acceptance

On f1852b7, `.scratch/text-font-corrected-check.log` passed the same full development command:
640 tests (134 MacPlatform / 150 Imaging / 296 Features / 60 Domain), 596 app translations,
both unsigned Debug builds and all doctor/isolation/format/freshness checks. Both Matt Pocock
review axes reread the correction and reported their findings fixed, with no new confirmed
issue. Fresh different-model code/security and fresh source-blind native acceptance passed;
the full criterion/command/evidence record is in acceptance-verdict.md.

The complete bilingual native command
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development scripts/e2e.sh --lang all --unsigned --no-build`
passed 45/45 scenarios per language at `.scratch/e2e/20261014-180114/{en,pt-BR}/report.json`:
164 images and 2,884 recorded assertions, including three explicit skips. Capture-focus's
activation positive control was skipped in each language; editor-presentation's activated
keyboard-owner check was skipped in Portuguese. These are not passing physical criteria.
Log: `.scratch/text-font-full-native.log`, exit0. The earlier Portuguese replacement-selection
keyboard failure did not reproduce; no product focus fix or root cause is claimed.
