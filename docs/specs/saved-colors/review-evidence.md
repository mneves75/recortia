# Saved colors — development evidence

Assumptions and acceptance were frozen in spec.md before implementation. Candidate remains
0.12.0/build 19; no new installation, tag, merge or public release occurred.

## Backend

Source-red/green evidence is retained in `.scratch/saved-colors-20261014/backend-evidence.md`.
The final package run passed 622 tests: 134 MacPlatform, 145 Imaging, 286 Features and 57 Domain.
Focused 48 tests cover bounds, normalization, persistence, legacy sealed consent, future schemas,
cross-editor visibility, apply undo/redo and refusals. A future incompatible-format regression
first failed five assertions, then passed after checking schema metadata before full decoding.

## Native acceptance remains open

The corrected source-red native run found `palette.save is accessible: value was nil`:
`.scratch/e2e/20261014-131702/en/report.json`. After implementing inspector controls, bilingual
`.scratch/e2e/20261014-131817` still failed both saved-colors and onboarding AX lookup. Isolated
repeat `.scratch/e2e/20261014-131919` failed; diagnostic run `20261014-131952` rendered the real
synthetic editor but found no SwiftUI accessibility children, only native focus-ring subviews.
This does not prove the product inaccessible, and does not qualify its controls. Temporary
diagnostic logging was removed; the required scenario and failure were preserved.

### Diagnosed harness correction

The public AX application query, scoped exclusively to the synthetic runner's own PID, succeeds
without a permission prompt and initializes SwiftUI's lazy accessibility nodes. The AppKit
unignored-child query alone did not do so (`20261014-133610`). The self-query restored onboarding
at `20261014-133704`; Save still failed because the editor host had never ordered its window.
Ordering the already parked synthetic editor restored native Save/Apply/Remove at `133910`.
These corrections affect the DEBUG harness only; no product permission or behavior changed.

Expanded bilingual native runs `20261014-134237` and `20261014-134457` pass 2/2 scenarios each:
onboarding and saved-colors. Actual AX assertions cover duplicate/full Save disabled state,
unsaved-color Remove disabled state, localized help and selected value, 12 native Save actions,
Apply/undo/redo, explicit Remove and no side-effect sinks. Rendering includes the native palette
and scrolled minimum-width dark inspector. The first expanded run failed the duplicate state
before observation settled; the standard SwiftUI settle resolved it, while preserving the failed
`20261014-134052` evidence. Independent UI and full-suite requalification are still pending.

The committed `21e712f` development gate passed 622 tests, 590 strings and two unsigned Debug
builds (`.scratch/saved-colors-committed-check.log`); hosted stable CI passed on that exact SHA:
https://github.com/mneves75/recortia/actions/runs/38598585844. The final harness correction requires
its own gate; these earlier checks do not qualify uncommitted source.

### Independent native acceptance and undo correction

A fresh source-blind GPT-6 Astra/high verifier independently drove the actual synthetic runner
at `dd3c615`, inspected six palette and twelve tour renders, and passed 828 assertions (4/4
scenario/language combinations). Own evidence: `.scratch/e2e/20261014-135250/{en,pt-BR}/report.json`.
The configured model differs from the builder; runtime identity is not exposed. Native scope
does not include cross-editor/relaunch persistence (independently covered by package tests),
physical VoiceOver/IME/Spaces, TCC, signing or release.

The full run at dd3c615 (`20261014-134637`) passed EN43/43 and PT-BR42/43. PT-BR failed
capture-focus's replacement-selection keyboard ownership assertion; cause remains unresolved.
Both languages recorded two activation-dependent skipped checks. No waiver or release claim.
Stable CI passed dd3c615: https://github.com/mneves75/recortia/actions/runs/38601175555.

A further adversarial check found that applying a saved color while a color-well adjustment
was pending merged the two actions into one undo group. Public-seam regression failed four
assertions (`.scratch/saved-colors-undo-boundary-red.log`); ending the prior continuous change
only after admission corrected it. Nineteen focused tests now pass, including refusal retaining
the ongoing group and a stale coalescer being unable to end a newer group
(`.scratch/saved-colors-undo-boundary-green.log`). This latest correction needs its own full
gate and independent backend recheck; earlier native acceptance remains artifact-specific.

Final correction acceptance: independent backend19 tests PASS and full development gate624
tests/590 strings/two Debug builds PASS. Source-blind native recheck on e6c259c also PASS:
`.scratch/e2e/20261014-140646/{en,pt-BR}/report.json`, 828 assertions/32 images, eight freshly
inspected renders. No backend findings remain; exact-head hosted CI is still pending at this
record. Supplemental complexity: `.scratch/saved-colors-complexity.json`, cccc1.8.0, five files,
218 functions, zero parse errors. Metrics do not prove behavior.

Later exact-head CI confirmation for e6c259c: SUCCESS,
https://github.com/mneves75/recortia/actions/runs/38603845235. This updates the earlier pending
CI record and does not resolve the full Portuguese capture-focus failure or qualify installation.

Capture-focus followup: diagnostics now include only the synthetic replacement window's
visibility, own key-window/responder match, own activation policy and unchanged-foreground
comparison. The predicate is unchanged. Isolated `20261014-142724` passed1/1 both languages,
each with the activation positive control skipped. This does not establish why the full run
failed; `.scratch/capture-focus-replacement-diagnostic.log` preserves that limitation.

Task-owned failed-build result bundle28KB remains at
`/private/var/folders/x_/ll566vlj2q72ssm7jsrt66f00000gn/T/ResultBundle_2026-14-10_13-52-0027.xcresult`:
the cleanup guard rejected its system-path deletion; no bypass was attempted. Native runners
exited and released their leases. Small cited synthetic evidence remains in scratch.

The initial app test had invalid fake-service names and failed compilation; these were corrected
before the meaningful native source-red run. The first full gate failed one formatting line;
it was corrected before rerunning. Logs are retained rather than reported as successful runs.

## Adversarial review

Matt Pocock Standards: zero mandatory violations, two low-severity duplication heuristics.
The duplicate Shell/editor AX implementation was replaced by one bounded shared helper.
The view's small availability predicate remains local to its protected-state message; no extra
public model API was introduced solely for that heuristic.

Spec: native acceptance is blocked; initial missing removal interaction was addressed with an
explicit Remove Current Color control and scenario assertion. Native enabled/disabled-state
inspection, full-palette interaction and complete bilingual visual qualification remain open.
Backend tests cannot substitute for these checks.

Stable-toolchain, independent native UI, live VoiceOver/TCC, physical displays, archive/export
and installed-app evidence remain separate. The existing RC development toolchain does not
qualify release. No full reference parity or production-readiness claim is made.
