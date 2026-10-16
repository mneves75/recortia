# Editable curved arrows — FP-034

## What the review changed

The plan advisor moved the head/shaft junction ahead of UI work, rejected coordinates of an
invisible Bézier control as the keyboard interface, and combined creation and editing into one
functional ticket. The visible bend handle, shared painted geometry and explicit degenerate
rejection are now acceptance requirements. CAP-01 remains an unrelated release blocker.

## Assumptions

The owner waived interviews and authorized reference-feature implementation. This is FR-05
editor work, not capture or automation. EN/PT-BR native controls and the current minimum editor
size remain binding. No new persistence, external transfer, permission, dependency or paid
service is authorized. A future-arrow preference is local to its editor, initially straight.
The existing 0.12.0/build19 source candidate is not an installed or released upgrade.

## Problem Statement

A straight arrow can obscure the content it points around. Recortia currently stores only its
two endpoints, so an author cannot bend an arrow and continue editing its shape.

## Solution

Add an editable quadratic curve to the existing arrow. A localized native Curved control
works for selected arrows and future arrows in that editor. A selected curved arrow exposes
its endpoints and a bend handle on the curve itself. Keyboard users can edit the visible bend
handle's document-space X/Y through native numeric controls. Straighten, move, resize,
duplicate, Undo and Redo retain the same annotation identity and privacy pipeline.

## User Stories

1. As an author, I want existing straight arrows to keep their appearance and behavior.
2. As an author, I want to create curved arrows directly after choosing Curved.
3. As an author, I want to curve or straighten selected arrows in one undo action.
4. As an author, I want the initial curve to visibly bend rather than merely change its label.
5. As an author, I want a handle on the painted curve to move the bend predictably.
6. As a keyboard user, I want labeled numeric fields for that same visible handle.
7. As an author, I want endpoint drags to retain the bend offset relative to their midpoint.
8. As an author, I want movement, resizing and duplication to preserve the curve.
9. As an author, I want a drag to undo once and Escape to abandon it without a history entry.
10. As an author, I want mixed selections to affect only arrows and describe mixed state.
11. As an author editing text, I want curve controls to leave my unfinished input alone.
12. As an author, I want a clear refusal of invalid geometry without losing document or Undo.
13. As an author, I want to select the painted curve rather than its empty endpoint chord.
14. As an author, I want the editor preview and sanitized PNG/JPEG exports to match.
15. As a privacy-conscious user, I want masks and magnifiers to keep their source-pixel guarantees.
16. As a Portuguese user, I want readable controls and truthful tour guidance.

## Implementation Decisions

- Extend the existing arrow with an optional quadratic control point; missing means straight.
  Do not add a generic path engine or an unrelated annotation kind. An isolated Swift prototype
  established language feasibility and unchanged sorted legacy JSON, not application acceptance.
- Store only endpoints and the control; derive the visible handle at parameter one-half.
  Moving that handle solves for the control. Numeric fields describe the visible handle,
  not the generally invisible control. Initial bend is a deterministic perpendicular offset.
- Translation and affine frame resizing transform all three points. An endpoint drag shifts
  the control by half of the endpoint displacement: this preserves the midpoint-relative bend
  vector, not constant curvature or orientation. Bend dragging and fields use the same command.
- Domain remains platform-independent. Shared Imaging geometry describes the actual stroked
  shaft and filled head; rendering, hit testing and painted bounds consume those components.
  Geometry objects are operation-local, with no mutable path cache crossing actors.
- Preserve the existing straight-arrow raster path. For curves, determine terminal direction,
  trim an exact quadratic prefix using De Casteljau and use a butt junction into the head.
  Do not assume distance/projection is monotonic over the whole curve. A bounded numerical
  method must identify the terminal branch and prove the junction fits; otherwise refuse.
  Offscreen pixel fixtures, not a second copy of the algorithm, decide whether there is a gap,
  protruding shaft or doubled opacity. No silent straightening or alternate head fallback.
- Coincident curved endpoints, nonfinite/overflowing geometry and an unconstructible head
  are explicit refusals. Existing degenerate straight behavior stays unchanged. Collinear,
  very short and extreme controls require deterministic tested outcomes. Admission precedes
  document/default/history mutations, including ending any prior continuous adjustment.
- The future default is independent of Undo for existing document edits. Selecting an arrow
  loads selected-state feedback without replacing the future default; mixed selection must
  expose mixed state rather than pretend every selected arrow matches the future default.
- Native controls are disabled during text input and after close. Rejected commands preserve
  selection, redo, active composition and an unrelated continuous adjustment.

## Testing Decisions

Prefer public editor commands and real sanitized exports, then the synthetic native app entry
point. Follow one red-to-green tracer at a time. Prior art is straight-line geometry/editor
tests, annotation rendering and paired-secret privacy tests. Required cases cover legacy JSON,
curve round-trip, bounds at extrema, near-curve versus empty-chord hit testing, both bend signs,
short/diagonal/reversed/extreme curves, endpoint and frame transforms, default creation,
mixed selection, atomic refusal, drag cancellation and undo/redo. Pixel tests cover the head
junction and opacity, fractional/doubled scale, rotated source layers, masks and magnifiers,
PNG/JPEG paired-secret equality plus unmasked positive controls. Native bilingual evidence
must show enabled/disabled controls, real curve pixels, bend fields, 25%/200% zoom and tour.
Physical keyboard/VoiceOver/Spaces and minimum-macOS qualification remain explicitly separate.

## Out of Scope

Other arrowhead styles, hand-drawn rendering, arbitrary vector paths, persisted projects,
capture changes, history, cloud/audio/video and proprietary internals. This closes the curved
arrow gap only; it cannot establish every arrow style other screenshot utilities offer, or full parity.

## Further Notes

Sources checked 2026-10-14: public feature pages of other screenshot utilities list several
arrow styles, including curved and bendable arrows. Public Core Graphics offers quadratic paths and stroked outlines;
the installed macOS15-compatible declarations and actual compilation must verify chosen APIs.

Alternatives: a separate curved-arrow case isolates representation but duplicates every arrow
consumer; a general path framework adds unneeded editing/serialization surface. The premise
challenge is to use freehand: simpler, but it fails precise editable-arrow behavior. Choose
the optional control and shared geometry. Five years later, one representation, no cached
derived paths and behavioral export fixtures should be easier to maintain than those options.
