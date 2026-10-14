# Text appearance

## Assumptions

The owner requested reference features and explicitly waived interviews. This is the next local
FR-05 slice, not a claim of complete competitor parity. Seven appearances will be independently
implemented: standard, rounded, monospaced, outlined, boxed, rounded boxed and monospaced boxed.
No proprietary font, asset or algorithm is copied. Existing system fonts and public Apple APIs
are used. No preference schema or export format is added. Pending text input must remain intact;
the appearance control is disabled until text editing finishes.

## What the advisor review changed

Accurate shared text metrics belong in ticket01, not after the font changes. Source inspection
found that EditorGeometry already measures Core Text and duplicates the renderer's logic;
those paths should share one stateless Imaging helper. Domain's character-count bounds remain
a platform-independent estimate, not authoritative text layout. Domain must stay free of AppKit.
Preserving wrapping means keeping the content-width constraint, not identical line breaks
across fonts. Font unavailability must be explicit. The real EditorTextEditing begin/commit/
cancel path and native text view must use the same appearance. Seven appearances are the
intended final result; the first ticket delivers three and cannot close the whole feature.

## Problem Statement

Text annotations currently offer size, color and rectangular fill, but cannot choose a rounded
or monospaced font, outlined glyphs or rounded text boxes. Font-size shortcuts would not close
this reference gap: CleanShot's public preview shows different font and decoration treatments.

## Solution

Offer a native localized Text Style selector for text creation and selected text. The first
vertical slice adds the three font designs. The second adds four decorations. Changing a style
is one explicit undo action; it preserves text, origin, size, wrapping and unrelated annotations.
The chosen appearance applies to new text in that editor and remains editable on existing text.

## User Stories

1. As a screenshot author, I want standard text to retain its current appearance by default.
2. As a screenshot author, I want rounded text for a softer label without changing its words.
3. As a screenshot author, I want monospaced text for code and aligned short labels.
4. As a screenshot author, I want outlined text that remains distinct on varied backgrounds.
5. As a screenshot author, I want rectangular and rounded text boxes for a clear callout.
6. As a screenshot author, I want a monospaced text box for a technical note.
7. As a screenshot author, I want to change selected text without restyling a selected shape.
8. As a screenshot author, I want the selected style to carry into my next text annotation.
9. As a screenshot author, I want Undo and Redo to restore appearance independently of a prior
   color-well gesture, without losing text or other edits.
10. As a keyboard user, I want native controls, readable names and selected values.
11. As a Portuguese user, I want localized controls and tour guidance at the minimum editor size.
12. As a user entering accented, multiline or composed text, I want style controls to preserve
    my unfinished input rather than force a commit or cancel it.
13. As a privacy-conscious user, I want every decorated export to retain opaque-mask guarantees.
14. As a user of existing documents, I want missing appearance metadata to mean standard text.
15. As a user closing an editor, I want later style commands to refuse without mutations.

## Implementation Decisions

- A small domain appearance value belongs to text content, not every annotation or a new
  settings database. Missing optional metadata resolves to standard appearance. Unsupported
  decoded values fail explicitly; no speculative migration or editable-file export is added.
- Editor style holds the current text appearance. Selection loads it from text; creation and
  duplication preserve it. Applying it edits selected text only and ends a prior continuous
  adjustment after admission, so one action has one undo step.
- The shared renderer uses the same public system font design for canvas and final export.
  Rounded/monospaced fonts must be demonstrably different, not labels pointing at the same font.
  Export pixel rendering stays on PrivacyRenderer's existing background execution path. Native
  canvas drawing and immediate interactive typography remain on their current UI path; this
  feature does not claim to move all text layout or canvas painting off the UI actor.
- Shared text metrics must replace the duplicate platform layout calculation in selection, hit testing,
  resizing and dirty bounds, and describe the same layout the renderer paints. `maxWidth` is
  the content constraint, excluding decoration padding; a different font may wrap differently.
  Interactive typography layout and background pixel rendering share immutable font choices
  and measured values, never mutable CTFrame/CTLine objects across operations. Measure cost
  before introducing any cache; do not retain annotation text globally after an editor closes.
- The chosen shared-layout placement is Imaging, which Features already uses. Replace its
  duplicate font/framesetter measurement with that helper; do not add AppKit to Domain or a
  persisted derived-layout cache. Only immutable geometry crosses operations. The numeric
  font-size control range is not a global cap: preserve existing valid resize sizes and reject
  nonfinite or unmeasurable geometry explicitly, without inventing a new numeric limit.
- Font resolution has a typed unavailable result. The model refuses that style before changing
  document/history; rendering cannot silently substitute standard glyphs for rounded text or
  omit text. Closed/active-input denial leaves a prior continuous adjustment intact.
- EditorTextEditing's beginNewText, beginEditingText, commitTextEditing and the native text
  view's font/layout must transport the appearance. Reopen/confirm/cancel, duplication and zoom
  preserve it without forcing marked text to commit.
- Plain appearances retain the existing fill behavior. Boxed appearances provide a white
  background when no explicit fill exists, with existing color/alpha able to customize it.
  The inspector must expose this truthfully as a background color, rather than an ineffective
  Fill toggle. An explicit transparent fill stays transparent; clearing it restores automatic
  white. Rounded boxes use a radius proportional to text size. Outlined monochrome glyphs use
  white interiors and the selected stroke color/width; color emoji retain their intrinsic color
  and remain visible. The actual outside stroke extent belongs in measured geometry.
- Decoration padding belongs in geometry and render layout consistently. Bounded font size,
  wrapping, finite geometry and existing memory limits remain binding. No hidden fallback,
  new worker pool, renderer replacement or cache based on raw secret pixels.
- Native controls use names and selected values, with no color-only meaning. Style changes
  refuse during active text composition, and the control explains how to finish editing.

## Testing Decisions

Pre-agreed public seams are the existing editor commands and final rendered exports, followed
by the native synthetic app entry point. The no-interview directive authorizes these seams.

One failing tracer bullet at a time: apply/undo and refusal through EditorModel; creation and
selection round-trip; legacy decode; literal glyph/font differences and box pixels through the
renderer; paired-secret source-independence exports for every appearance. Expected values come
from independent fixtures, not a second copy of rendering math. Existing editor, Unicode and
RED tests remain required. No private helper tests, real screen content or system settings.

Concrete layouts include composed accents, RTL, emoji, narrow content width, canvas-edge
placement, scaling, masks and magnifiers. Final ink must fit the advertised text geometry.
Unknown decoded appearance values reject explicitly. Backend work must demonstrate background
pixel rendering and contain font/layout objects within each operation.

Native EN/PT-BR tests must operate the selector and observe selection/new text/undo. Inspect
actual standard and minimum-width dark renders. Then run the full development gate, focused
adversarial code review and fresh independent native acceptance. Stable release, physical
VoiceOver/IME/Spaces and signed installation are separately qualified.

## Out of Scope

Saved user-named text presets, new fonts, rich-text editing, project file export, screenshot
history, cloud, recording and proprietary internals. These are distinct matrix rows, not
implicitly satisfied by seven text appearances.

## Further Notes

Choice: extend the existing text content and shared renderer. Font-size/color presets are the
smallest rejected alternative but miss the actual visual feature. Replacing annotation editing
with a rich-text framework adds state and export/privacy obligations the request does not need.
Five years later, a small typed value, native controls and export proof are easier to maintain
than copied assets or a second rendering engine.

The initial SwiftUI radio-group selector was visible but neither its accessibility Press nor
a self-window event at its fresh accessibility frame changed the binding in the synthetic
runner. Explicit native choice buttons with checkmarks and selected accessibility values
passed the same model/undo acceptance. That is the chosen control; keyboard tab/activation and
physical assistive-technology qualification remain distinct from synthetic Press evidence.

Primary reference verified 2026-10-14: [CleanShot features](https://cleanshot.com/features),
including its public seven-style preview. Marketing security/performance statements are not
Recortia evidence. Existing styles are not promised until their own pixel and native tests pass.

Status: ticket01 verified-development on f1852b7 with full gate and fresh independent
code/security/native acceptance. Ticket02 is in progress; native input feasibility passes
but its four appearances are not accepted yet. No
text-appearance release, complete seven-style qualification or installation is claimed.

API feasibility evidence: `.scratch/text-font-feasibility-20261014/evidence.md`. The strict
Swift6/macOS15 prototype resolves fonts through public NSFontDescriptor APIs without actor
suppression; background probe measurements differ for rounded and confirm equal monospaced
i/W widths. This is API feasibility, not feature or render/export qualification.
