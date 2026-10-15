# FP-034 development evidence

This is work in progress, not feature acceptance. Plan baseline: 9f30493. No native curved-arrow
UI, physical keyboard/VoiceOver or signed-install qualification is claimed. The earlier CAP-01
full-suite FAIL remains open; this feature does not change capture focus.

## Planning and ownership

Primary reference research and main-session alternatives are in spec.md. A configured
GPT-6 Astra/high plan-only advisor challenged terminal-branch assumptions and invisible control
coordinates. Its review changed the plan before implementation; it inspected no source and
executed no tests. Dispatch model identity is configuration, not runtime attestation.

Main owns Features/native UX/integration. A configured GPT-6.1 Sol/xhigh backend worker owns
Domain/Imaging/tests and mechanical enum-pattern arity updates; no overlapping writers or
simultaneous source edits/compilation are allowed. Package and native build leases are separate.

## First shared tracer — observed RED

After the worker's independent Domain coding/transform tracer reached green, main added a
public EditorModel creation/straightening/default/Undo test. With source edits paused in both
lanes, main ran:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development \
  swift test --package-path Packages/RecortiaKit \
  --filter 'EditorCurvedArrowTests|CurvedArrowLayoutTests'
```

Exit1; compile errors identify missing `setArrowCurved`, `curvedArrows` and `selectedArrowBend`.
Log: `.scratch/curved-arrows-main-20261014/creation-layout-red.log`. The filter also named the
worker's newly written layout tracer, but compilation stopped in FeaturesTests before that
test was compiled/executed: this run does not establish an observed layout regression. Both
lanes resumed source edits afterwards. No green result or final geometry feasibility is yet
recorded here.

## Subsequent editor tracers

The worker's `.scratch/curved-arrows-backend-20261014/head-gesture-tracer.log` captured the
new bend/endpoints/cancel regression failing with five behavioral issues. Main added the
on-curve handle, midpoint-to-control conversion and half-delta endpoint adjustment, with
layout admission before document mutation. Numeric bend input then failed compilation on
the missing public command (`numeric-bend-red.log` in the main scratch directory); the command
and painted-curve hit testing were implemented. The coordinated
`head-numeric-green-corrected.log` records all three editor tests passing. Its first attempt
had a test-helper Comment type error, corrected without a product/threshold change.

The explicit invalid-bend notice tracer failed compilation on missing `.arrowGeometryRefused`
(`invalid-bend-red.log`); main added the typed refusal and bilingual copy. The worker's
`refusal-green.log` records all four editor tests passing, including preservation of an active
continuous adjustment before geometry admission. These logs are under
`.scratch/curved-arrows-backend-20261014/` unless named as main scratch above.

Backend head/junction corrections, actual stroke-alpha RED and the approved one-pixel coverage
oracle correction are recorded in the worker's `.scratch/curved-arrows-backend-20261014/evidence.md`.
The normal-size connectivity threshold remains intact. No full feature acceptance is implied.

## Main geometry and native corrections

All commands below use the explicit Xcode27.1 RC developer directory and development mode.
Package commands are `swift test --package-path Packages/RecortiaKit --filter EditorCurvedArrowTests`.
Main logs are under `.scratch/curved-arrows-main-20261014/`.

- `privacy-move-tracer.log` in the backend directory captured the move regression's five
  issues. Main validates curved-arrow geometry before committing a translation and maps its
  typed refusal separately from redaction errors. The subsequent backend regression command
  passed96 named tests. A valid small move and Undo were also added as positive controls.
- `width-admission-red.log`: five issues; a40px stroke made a valid4px-long curve
  unconstructible and mutated the future style. Admission now precedes both style/document
  mutation. `width-admission-green.log`: six editor tests pass, including a valid2px width.
- `frame-refusal-red.log`: one issue, the curve-frame refusal was mislabeled as redaction.
  The curve-specific public frame path now maps failures accurately;
  `frame-refusal-green.log`: seven tests pass.
- `endpoint-refusal-red.log`: one missing-notice issue. Typed geometry refusal now reaches the
  gesture notice before any mutation; `endpoint-refusal-green.log`: eight tests pass, with a
  valid endpoint-drag/Undo positive control. `creation-refusal-red.log` similarly captured a
  misclassified new-curve refusal; `creation-refusal-green.log`: nine tests pass.
- `nonfinite-bend-red.log`: two missing-notice issues for NaN/infinity. Refusal now explains
  those inputs after open/input/selection admission, before mutations. A separate local-default
  and closed-editor test passes. `nonfinite-bend-green.log`: eleven named editor tests pass.

Native commands are `scripts/e2e.sh --lang all --only curved-arrows --unsigned`, with the same
developer directory/development mode. The first build exposed the new notice missing from the
exhaustive persistence mapping (`native-controls-red.log`, exit2); it was added as persistent.
The corrected build's native baseline found no `arrow.curved` node in either language:
`.scratch/e2e/20261014-202814`, exit1. After controls were implemented, initial action tests
used a hidden synthetic window; adding a wait did not fix that. Ordering only the parked test
window, matching existing control scenarios, produced bilingual PASS in
`.scratch/e2e/20261014-203112`. This is test setup, not a production-focus change.

`native-bend-fields-red.log` records missing Bend X/Y nodes; after native fields were added,
`.scratch/e2e/20261014-203316` passed. Real field-editor insertion and Return then found a
product bug: committing Y immediately after X restored old X. Both original failures remain
in `native-numeric-submit-tracer.log`. A diagnostic run
(`native-numeric-focus-diagnostic.log`) confirmed the correct focused fields, with actual bend
235,170 instead of280,170. Successful commit had synchronously reloaded an obsolete view value.
The field now retains successful state and reloads only on refusal or observed model changes;
no synchronization delay was added between numeric commits. Bilingual
`.scratch/e2e/20261014-203857` passed, including Portuguese decimal formatting.

Expanded native qualification in `.scratch/e2e/20261014-204622` passed1/1 scenario per language,
146 assertions and11 PNGs each. It verifies mixed controls/description and Undo, independent
future defaults, duplicate identity/geometry, actual red curve pixels at displayed25%/200%,
980×560 dark controls and disabled controls during marked native text input. Main inspected
both initial language layouts, both zoom rasters and Portuguese compact/disabled dark images.
All sources are generated; the numeric driver focuses only its own AX element, inserts into
its native field editor and sends Return to its own window. No global input/TCC is involved.

Tour copy and final boundary checks have since been updated. Full gate, final broader native
integration and independent source/native acceptance remain pending. Physical keyboard/IME,
VoiceOver, minimum-macOS runtime, performance and signed distribution remain unqualified.
The earlier CAP-01 FAIL remains unresolved; none of these results authorizes release/install.

Final focused native smoke (`native-final-smoke.log`) passed `curved-arrows,onboarding` in
both languages at `.scratch/e2e/20261014-205448`: onboarding236 assertions/13 PNGs and
curved-arrows149 assertions/12 PNGs per language. It includes the new tour copy, compact dark
refusal notice and native field-target focus check. Main inspected Portuguese normal/compact
tour and compact refusal images. The compact tour remains a native scrollable page.

Self-review then centralized the already-tested geometry admission helper across creation and
curve commands, removing a duplicate Imaging import/check. No semantic contract changed;
`shared-admission-refactor-green.log` passed all eleven editor tests. Full gate/independent
acceptance follow on the frozen code candidate; this final smoke predates that small helper
consolidation, while the later required full native run must cover the final candidate.

## Adversarial source review and corrections

The two fresh, read-only Sol 6.1/xhigh review contexts examined `03c2a67…d0326ba`:
Spec found collinear frame refusal and premature adjustment closure on refused endpoint drags;
Standards found canvas expansion admitting a translated curve whose endpoints collapse through
floating-point precision. Neither reviewer executed tests or the app.

The frozen `d0326ba` unsigned development gate passed (`full-check.log`): 134 MacPlatform,
167 Imaging, 315 Features and 62 Domain tests (678 total), 617 translated strings, app and E2E
target builds. This predates the corrections below and is not final-candidate acceptance.

- `collinear-frame-behavior-red.log`: ten failed expectations across horizontal/vertical,
  reversed-endpoint frame edits. An earlier test draft failed compilation for an omitted
  style argument (`collinear-frame-red.log`); only the corrected run demonstrates the defect.
  `collinear-frame-green.log`: 22 editor tests pass. Segment progress on the nonempty axis
  now gives collinear arrows extent, matching existing lines instead of silently ignoring it.
- `canvas-shift-red.log`: six failures prove invalid geometry committed and discarded Redo.
  `canvas-shift-green.log`: 14 curve/composition tests pass after shifted curves are admitted
  inside the atomic document transaction. Ordinary 40-point growth and Undo are positive controls.
- `gesture-adjustment-red.log`: three failures prove a refused/cancelled endpoint drag closed
  the previous adjustment. `gesture-adjustment-green.log`: 45 editor gesture tests pass.
  Move/resize groups now start on the first admitted document change; refusing or cancelling
  before that point preserves the open adjustment. An admitted drag remains a separate Undo.
- `creation-adjustment-red.log`: one failure exposes the same premature closure on curved
  creation. Creation now ends the preceding adjustment only after geometry admission.
  `creation-adjustment-green.log`: 46 editor gesture tests pass.

Standards also raised an unconfirmed resource-risk question about Core Graphics stroking/union
on very large finite coordinates. Bounded solver iterations alone do not qualify framework
resource usage; do not describe that risk as a reproduced failure or a measured performance pass.

The earlier plan-only hosted run `38652457209` failed three assertions in the text appearance
creation/reopening test (`earlier-plan-ci-failure.log`); the later `03c2a67` run passed.
No causal diagnosis or fix is established by that later success. Preserve this incident separately
from CAP-01 and the curved-arrow focused evidence.

## Final independent duplication correction

Fresh different-model code/security acceptance on `08ec884` reproduced a duplication admission
gap: a valid collinear curve with endpoints separated by `1e-16` at the origin loses that
separation after the ten-point duplicate offset. The original six near-ULP fixtures did not
reproduce it; the smaller fixture did. Preserve the initial FAIL in
`.scratch/curved-arrows-final-acceptance-20261014/verdict-initial.md`.

The public `EditorCurvedArrowTests.duplicateAdmission` tracer reached the tiny curve through
frame editing and observed seven failed expectations in `duplicate-admission-behavior-red.log`.
The earlier `duplicate-admission-red.log` is only a sandbox manifest failure. Duplication now
validates the translated curve inside the atomic edit before appending it or changing selection.
`duplicate-admission-green.log` passed 43 curve/replay/composition tests, including retained
Redo and an ordinary-size duplicate/Undo positive control.

The native operator scenario now explicitly reports curve endpoint/bend drags, Undo/Redo,
Escape-equivalent cancellation and the tiny-curve duplicate refusal. Those gesture calls are
synthetic public editor inputs, distinct from the real native control/field-editor actions;
they do not qualify physical pointer/keyboard events. Final rebuilt acceptance follows.

Stable Xcode CI passed on `08ec884`:
https://github.com/mneves75/recortia/actions/runs/38659153698.
This evidence predates the duplication correction and does not replace its final gate.
