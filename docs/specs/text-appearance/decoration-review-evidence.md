# Ticket02 integration evidence

Scope: FP-033 / FR-05 text decorations; source baseline a3ad94e, reviewed plan3654a07.
Implementation is under verification, not accepted or installed. Candidate metadata remains
0.12.0/build19. All native inputs are generated fixtures with isolated settings and private
pasteboards; no real screen capture, TCC changes, personal content or network transfer.

## Backend

The disjoint backend worker used the approved public seams and incremental red/green tracers.
Its exact commands and failures are recorded in
`.scratch/text-decorations-20261014/backend-evidence.md`. Main inspected the returned source.
The local future boxed-text background is separate from shape/plain-text fill; sole selection
loads its actual retained fill through the existing didChange boundary. Core Text objects stay
operation-local. No renderer/privacy algorithm or dependency was replaced.

Main personally reran:

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development swift test --package-path Packages/RecortiaKit --filter 'TextDecorationExportTests|EditorTextDecorationTests|TextAppearanceExportTests|EditorTextAppearanceTests|TextAppearanceTests|AnnotationRendererTests|EditorCanvasRendererTests'`

PASS: 41 tests (19 Imaging / 19 Features / 3 Domain), exit 0. This rerun includes the corrected
ExportError.render wrapper expectation. Log: `.scratch/text-decoration-focused-main.log`.

## Native red/green tracers

All commands below use the same explicit development environment as above, followed by
`scripts/e2e.sh --lang <language> --only text-decorations --unsigned`.

1. Outlined input: `.scratch/text-decoration-native-red.log` built successfully and failed
   because the real NSTextView lacked stroke-and-fill attributes. One-time storage/typing
   attributes and white glyph interiors passed EN/PT in
   `.scratch/text-decoration-outline-native-green.log`, including inserted Unicode and
   programmatic marked text through zoom. Native font/color updates do not replace marked
   ranges. This does not qualify physical IME.
2. Live box: `.scratch/text-decoration-box-native-red.log` failed on a literal padding pixel
   (gray230 instead of yellow255/214/0). A passive, noninteractive view now draws the shared
   background beneath the native text view. EN/PT passed in
   `.scratch/text-decoration-box-native-green.log`; no NSTextView rectangular background or
   clipping is used as a substitute for rounded geometry.
3. Background controls: the unchanged artifact failed because textBackground.reset was absent
   (`.scratch/text-decoration-background-controls-red-retry.log`). Localized Background Color
   and Reset now call the boxed-only command, disable during text input, and replace the
   misleading Fill toggle in boxed-text context. EN/PT passed native Reset/undo/redo in
   `.scratch/text-decoration-background-controls-green.log`.
4. High-zoom containment: visual inspection exposed image/input pixels over the object list
   and toolbar. `.scratch/text-decoration-canvas-clipping-red.log` reproduced a changed pixel
   in the adjacent object list. Explicit NSView.clipsToBounds fixed the canvas boundary;
   `.scratch/text-decoration-canvas-clipping-green.log` passed text decorations, font designs
   and failure clearing in both languages. The selected SDK's NSView.h documents a NO default
   since macOS14; the explicit property is available since macOS10.9. No deployment-target
   change was needed.

Initial test setup failures are retained: a test-only pixel-type compile mismatch; an
out-of-viewport pixel sample crashed at `.scratch/e2e/20261014-182419/en/runner.log`. The test
now fits the generated document and bounds-checks its sample. One background-control run
exited0 without a report (`.scratch/e2e/20261014-182554/en`); the unchanged artifact was rerun
and produced the actual missing-control RED. No root cause is claimed for that early exit.

Expanded native qualification initially read selected AX values before SwiftUI refreshed;
`.scratch/text-decoration-native-integrated.log` records those failures in both languages.
The checks now settle the real view before reading its selected state, matching the existing
three-font scenario. Model changes, native input and the existing font/failure scenarios had
passed; the failed run is not acceptance evidence. The corrected tour-integrated run passed
four scenarios per language and 52 images at `.scratch/e2e/20261014-182909/{en,pt-BR}/report.json`.
Log: `.scratch/text-decoration-native-tour-green.log`. Subsequent clipping and literal native
glyph-pixel checks refine that evidence; final acceptance remains pending.

Final focused literal native glyph checks passed in both languages at
`.scratch/e2e/20261014-183319/{en,pt-BR}/report.json` (nine images per language), log
`.scratch/text-decoration-native-pixels.log`. A thin selected stroke lets the rendered initial
monochrome glyph demonstrate both white interiors and colored outlines against a black ground;
the sampled columns exclude the later color emoji. This complements the wide/zero-stroke
export bounds controls. Main inspected native font/decorations, compact-dark controls and the
Portuguese tour editing page; all labels remain readable, with scrolling for longer content.

Complexity evidence: cccc1.8.0, `--no-cache --min 0`, twelve explicitly named changed production
Swift files, 475 functions, zero parse errors, exit0; `.scratch/text-decoration-complexity.json`
and `.stderr`. This is advisory evidence and does not replace correctness or independent review.

## Limits and remaining gates

The local toolchain remains Xcode27.1 RC27A9275 / Swift6.4 / SDK27.0, targetmacOS15, on
macOS27.2/26B5112a arm64. Full gate, final bilingual native evidence, two review axes and fresh
independent code/security/native acceptance are pending. Physical IME/VoiceOver/Spaces,
minimum-OS runtime, performance budgets, signed installation and release remain unqualified.
During input the caret/selection remain full strength; no whole-view opacity is applied.
Final export opacity is covered by the shared-renderer tests.
