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
