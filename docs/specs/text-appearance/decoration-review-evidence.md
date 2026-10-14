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

## Matt Pocock review axes on 15dd74f

### Standards

Fresh configured gpt-6.1-sol/xhigh: no confirmed documented-standard breach. One nonblocking
P3 heuristic: outline percentage conversion occurs in Core Text layout and twice in native
attribute/admission code. The reviewer found current calculations consistent. Different
framework attribute adapters remain explicit; this suggestion is not a correctness failure.
The review read the fixed source/callers and ran no tests or GUI actions.

### Spec

Fresh configured gpt-6.1-sol/xhigh: one confirmed P2. Reset Background relies on the local
future-text default, which is synchronized only for sole selection. In a mixed selection a
colored boxed annotation can therefore have disabled Reset and a misleading white color well;
undo can leave that display stale. The boxed-only model command itself is correct. Main is
adding a native regression, then deriving the control value/eligibility from selected boxed
annotations, with an explicit mixed-colors indication when necessary. The reviewer also
identified decorated native wrapping as a coverage gap, not a demonstrated rendering defect.
No scope creep or other confirmed behavior defect. No tests or GUI actions were run by this
axis. Both axes will rereview the complete correction before final independent acceptance.

One finding in each axis: Standards has one nonblocking judgement; Spec has one P2 defect.

The mixed-selection defect was reproduced by real native controls in
`.scratch/text-decoration-mixed-background-red.log`: Reset was disabled with a selected yellow
box and unrelated image layer while the future default was nil. The inspector now derives
its color from selected boxed annotations and Reset eligibility from both selected explicit
fills and the future default. EN/PT native color-well, Reset, undo and renewed eligibility
checks passed at `.scratch/e2e/20261014-184207/{en,pt-BR}/report.json`, log
`.scratch/text-decoration-mixed-background-green.log`. A separate different-fill indication
tracer is in progress; no completed correction review is claimed yet.

Different-fill description: `.scratch/text-decoration-mixed-caption-red.log` failed on the
absent native text. A localized mixed-background caption now accompanies the color well.
The first check incorrectly queried a static text's accessibilityLabel; the selected SDK's
NSAccessibilityStaticText protocol requires accessibilityValue. The unchanged production
caption passed the corrected value check, Reset and undo in both languages at
`.scratch/e2e/20261014-184444/{en,pt-BR}/report.json`, log
`.scratch/text-decoration-mixed-caption-value-green.log`. The temporary helper label case was
removed; the shared accessibility helper has no net change.

The expanded corrected native run passed four scenarios per language, 60 images at
`.scratch/e2e/20261014-184545/{en,pt-BR}/report.json`, log
`.scratch/text-decoration-corrected-native.log`, including four decorated wrapping/composition
cases. Integration then corrected an older test-unit mismatch: viewport scales0.25/2.0 are
not displayed25%/200% on a Retina host. Both original-font and decoration wrapping tests now
divide by backingScale and assert zoomPercent explicitly. The final rerun passed four
scenarios and 30 images per language at `.scratch/e2e/20261014-184750/{en,pt-BR}/report.json`,
log `.scratch/text-decoration-corrected-native-zoom.log`. Old reports do not retroactively
prove the displayed percentages.

## Native wrapped glyph correction

Visual inspection of the nominally passing wrapped screenshots found missing Arabic/Latin
lines. TextKit 2 reported correct multiline usage bounds while its rendering surfaces stayed
at their initial single-line height. The true pixel regression failed for all four decorations
in `.scratch/text-decoration-native-wrap-pixels-red.log`. Public viewport layout, view
invalidation and explicit layout invalidation also failed; logs are
`.scratch/text-decoration-native-wrap-viewport.log`,
`.scratch/text-decoration-native-wrap-invalidation.log` and
`.scratch/text-decoration-native-wrap-relayout.log`. These failed recovery branches were removed.
An earlier diagnostic accessed layoutManager on TextKit 2 and switched engines during marked
input; that instrumentation was removed and is not product-failure evidence.

The same native text view now selects TextKit 1 at construction, without runtime switching,
fallback or a second editing renderer. Core Text canvas/export is unchanged. The plan records
the alternative and five-year tradeoff. The plan-only Astra advisor supported this choice if
the unchanged input/pixel criteria pass; it ran no code or tests. The initial English probe
passed at `.scratch/e2e/20261014-190326/en/report.json`; actual wrapped images show all lines.
Temporary layer/debug instrumentation was removed. Retained tests check real lower-line ink,
native glyph anchors on every line, exact displayed zoom, marked/selected ranges, content-width
preservation and unchanged Unicode confirmation. Final bilingual and full-gate evidence follows
after those checks complete; older geometry-only PASS reports do not prove visible glyphs.
The cleaned bilingual four-scenario run passed at
`.scratch/e2e/20261014-190720/{en,pt-BR}/report.json` (60 images), log
`.scratch/text-decoration-native-fixed-engine-bilingual.log`. Further visual inspection found
that composed suffix characters could retain the font size from the smaller zoom after
unmarking. That run therefore does not establish complete native visual acceptance. A separate
font-size regression and native plaintext-paste/deletion/undo qualification are in progress.

The font-size regression failed for all four decorations in
`.scratch/text-decoration-composed-font-size-red.log`. Updating storage during zoom alone
did not fix it (`.scratch/text-decoration-composed-font-update.log`): AppKit restores cached
pre-composition attributes at unmarking. The correction retains one presentation font,
updates only that attribute and reapplies it after native unmark/insertion. Strings, selected
and marked ranges, outline attributes and undo records are not replaced. The private-paste
test initially expected separate undo actions from programmatic edits in one event group;
actual undo restored the exact pre-paste draft in one action. The retained assertion checks
that native group, rather than claiming separate physical key events were exercised.
The corrected bilingual run passed four scenarios and 30 screenshots per language at
`.scratch/e2e/20261014-191222/{en,pt-BR}/report.json`, log
`.scratch/text-decoration-native-composition-restoration.log`. Actual wrapped images were
inspected; Arabic, Latin, emoji and the composed suffix are visible at the proper font size.
This includes private plaintext paste, deletion, grouped native undo and unchanged confirmation.
Only formatting changed afterward. Full correction gate and independent acceptance remain pending.

## Gate and remaining qualification

Full development gate on15dd74f passed:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development scripts/check.sh --unsigned`.
656 package tests (134 MacPlatform / 158 Imaging / 304 Features / 60 Domain), both unsigned
Debug targets, 603 extracted-string translations, doctor/isolation, strict formatting and
generated-project freshness all passed, exit0. Log: `.scratch/text-decoration-full-check.log`.
The earlier default-target localization invocation saw the previous production target's stale
strings data while only E2E had rebuilt; the correctly selected E2E target passed614 extracted
strings, and this full gate rebuilt production and passed603. No missing translation remains.

Complete native suite on15dd74f passed46/46 per language, 3,180 recorded assertions and182
images at `.scratch/e2e/20261014-183620/{en,pt-BR}/report.json`, log
`.scratch/text-decoration-full-native.log`, exit0. Each language explicitly skipped its
capture-focus activation positive control because the host declined activation. Those two
checks are SKIPPED, not physical passes. The previous editor-presentation activation skip did
not recur. This run predates the mixed-selection correction and cannot prove that missing
case; corrected full-suite evidence remains required.

Hosted stable CI on15dd74f also passed656 tests, 603 translations and the full unsigned gate
using Xcode27.0/27A266a (run38641396849). Actual job-log proof is retained at
`.scratch/text-decoration-ci-15dd74f.log`; the API download went directly into the repository's
scratch rather than gh's outside cache. This is the pre-correction source, not acceptance of
the mixed-selection fix or local release qualification.

The local toolchain remains Xcode27.1 RC27A9275 / Swift6.4 / SDK27.0, targetmacOS15, on
macOS27.2/26B5112a arm64. Complete native-suite evidence, two review axes and fresh
independent code/security/native acceptance are pending. Physical IME/VoiceOver/Spaces,
minimum-OS runtime, performance budgets, signed installation and release remain unqualified.
Native input retains the existing full-strength glyph treatment and caret/selection; no
whole-view opacity is applied. The passive box honors its saved opacity, while committed
canvas/export applies saved annotation opacity as a group. Live glyph opacity is therefore a
temporary editing limitation. Final group opacity is covered by shared-renderer tests.
