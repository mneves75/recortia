# Straight-line annotation

## Assumptions and scope

The owner's reference-feature request and no-interview instruction authorize this local slice.
FR-05 / EDIT-01 / EDIT-02 gain a straight segment without arrowheads. Existing arrows remain
unchanged. No dependency, storage format, permission or external export destination is added.

## Behavior and seams

- `Annotation.Kind.line(start:end:)`: document-space endpoints, translation, resize and Codable
  roundtrip. Stroke/opacity apply; fill is irrelevant. Bounds include half the stroke, no head.
- `EditorModel`: toolbar/shortcut D activates Line; one drag adds one object and one undo step.
  Shift constrains the creation drag to 45-degree increments. Endpoint handles resize it without
  snapping, matching existing arrow endpoint editing; selection follows only
  the stroke segment. Move, duplicate, delete and undo/redo use existing commands.
- A click without a meaningful drag creates nothing; cancel removes the draft. Invalid geometry
  is rejected/skipped by the existing public model/render boundaries.
- `AnnotationRenderer` is shared by canvas and export. Literal pixel fixtures prove a visible
  round-cap segment and no arrowhead. Export remains flattened through ShareSnapshot; an opaque
  mask replaces line pixels and source pixels in the final artifact (RED-02/03).
- App controls, object-list labels and help are localized EN/PT-BR. Keyboard shortcuts remain
  suppressed during text input. No UI redesign or custom rendering surface is introduced.

## Choice

Use a distinct typed line case and existing gesture/renderer paths. A two-point freehand alias
would avoid enum work but lose endpoint-specific editing and clear object semantics. Removing
arrowheads through a new arrow-style flag would mix two distinct tools and broaden arrow state.
The explicit case keeps the interface small and lets compiler exhaustiveness find callers.

## Acceptance

Test one public seam at a time: red missing line API; green geometry/model behavior; then literal
render and secure export fixtures. Run focused package suites, full development gate and actual
native synthetic EN/PT-BR editor replay. Stable release/physical qualification remains separate.
Add no production workaround for the previously unresolved focus/occlusion failures.

Status: source implemented; final gate and independent acceptance in progress. Focused final
geometry/editor/render/export/RED suites passed 62 tests; red tests caught missing APIs, endpoint
handles, axis-aligned setFrame refusal and cross-axis collapse. A mask-ignore mutant was detected
and RenderEngine restored byte-for-byte. Evidence: `.scratch/straight-line-20261014/`.
Native bilingual annotations/onboarding/pixel-tools checks passed; actual minimum-width regression
failed at 1019 points, then passed at 980 with the compact-control fallback. Evidence:
`.scratch/straight-line-toolbar-red.log`, `.scratch/straight-line-toolbar-green.log`,
`.scratch/e2e/20261014-102013/`. The complete source still needs its final gate/E2E and review.
Intended candidate remains 0.12.0/build 19; no beta tag or installation is claimed.
