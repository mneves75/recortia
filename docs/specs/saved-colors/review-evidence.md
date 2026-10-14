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
