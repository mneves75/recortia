# Text appearance implementation plan

## What the review changed

Ticket01 is accepted on f1852b7. A plan-only advisor reviewed ticket02 against its actual
callers. Style must be an explicit argument to measurements: defaulting it would let outline
admission/selection forget the real line width. Native text backgrounds cannot be assumed to
match a padded rounded decoration. Keep that decoration passive and separate from text input.
Preserving color emoji, stroke bounds and composition must be demonstrated, not inferred from
Core Text or NSTextView API names.

## Assumptions and scope

The owner waived interviews and approved reference-feature implementation. Add only the four
remaining appearances: Outlined, Boxed, Rounded Box and Monospaced Box. No font asset, dependency,
cache, preference, external format or renderer replacement. Preserve the existing editor and
public plaintext editing behavior. App copy remains English/pt-BR. Physical IME/VoiceOver and
release checks stay separate. The source baseline is a3ad94e, containing the accepted three-font
slice. This plan and its reviewed spec authorize the public seams below without another stop.

## Decisions

- Keep seven typed appearance values. Resolve system fonts exhaustively: Standard/Outlined/
  Boxed use standard, Rounded/Rounded Box use rounded, Monospaced/Monospaced Box use monospaced.
- Require `TextLayout.metrics(for:style:)`; update every caller atomically. Keep `contentFrame`
  and its maxWidth unchanged. Add an optional background frame and its document-space corner
  radius, separate from the final visual frame. Padding extends outside the content; it does
  not reduce wrapping width or move the text origin. Use proportional padding/radius constants
  chosen in this implementation, not copied from a competitor.
- Outlined monochrome glyphs have white interiors and the chosen stroke color/width. Apple's
  negative Core Text stroke-width percentage supports stroke+fill, but actual outside ink,
  joins, fallback and color emoji need pixel controls. Zero line width stays a valid zero
  outline; invalid/nonfinite arithmetic refuses before mutation/drawing.
- Boxed backgrounds resolve nil fill to white. Explicit transparent RGBA stays transparent;
  Reset restores nil. Switching to a plain appearance retains stored fill, whose legacy plain
  behavior remains unchanged. A background command affects selected boxed text and the local
  future-text fill default; it does not restyle selected shapes or plain text. Normal continuous
  color adjustments coalesce; Reset is an admitted discrete undo action.
- EditorTextEditing carries one immutable Annotation.Style snapshot. Preserve its read-only
  color accessor if callers need it. Snapshot style/appearance/input are retained through
  reopen/cancel/confirm; editing does not mutate the annotation on every keystroke.
- Use public native text attributes for editable outlines only after a focused feasibility
  check. Initialize storage/typing attributes before input begins, retain plaintext paste, and
  avoid replacing strings, selections or whole attribute dictionaries during viewport updates.
  Apply only the presentation font across the existing storage, preserving outline attributes.
  AppKit can restore pre-composition font attributes when marking ends; reapply the current
  presentation font after native unmark/insertion without replacing input or undo records.
  Preserve caret/selection visibility;
  do not fade the whole NSTextView to apply annotation opacity.
- Select TextKit 1 once when constructing the same native NSTextView. A real glyph-pixel
  regression found TextKit 2's rendering surfaces stuck at their initial single-line height
  after wrapped input resized; layout bounds alone passed. Public invalidation, viewport
  layout and view invalidation did not restore the missing glyphs. Do not switch engines
  during composition or keep a fallback branch. The strongest alternative is retaining
  TextKit 2 with a small public fix, but the tested fixes failed. A single reversible native
  constructor choice and visible-line regression are cheaper to maintain five years later
  than a recovery chain or custom editing renderer. Core Text canvas/export stays unchanged.
- For padding/rounded boxes, prefer a small noninteractive decoration view behind the existing
  text view, using the same background renderer and geometry. It owns no input, tracking,
  windows, raw pixels or exports. If native live decoration cannot preserve composition,
  explicitly document its temporary editing limitation rather than claim visual equivalence.

## Approved seams and ownership

Backend worker owns Domain/TextAppearance, Imaging/TextLayout and AnnotationRenderer, affected
Features geometry/appearance/editing state and related package regressions. Main owns App
views, native text integration, strings, E2E, docs, integration and final acceptance. No shared
file writers; communicate before any ownership extension. No concurrent app builds or mutable
package builds; freeze source for main's native red/green cycles.

- `TextLayout.metrics(for:style:)` throws TextLayoutError with the actual style mandatory.
- `TextLayoutMetrics`: content frame, total visual frame, optional background frame and corner
  radius, all immutable and document-space. Core Text objects remain operation-local.
- `AnnotationRenderer.drawTextBackground(_:style:in:)` draws only the shared text background
  from TextContent/Annotation.Style and propagates RenderError; native decoration uses it.
- `EditorModel.setTextBackgroundColor(_:) -> Bool`: boxed-text-only mutation, nil Reset, public
  undo/refusal/continuous-adjustment behavior. Active input/closed editors refuse; failures
  expose an existing localized notice. Shape/plain-text selections remain unchanged.
- Existing setTextAppearance, nativeFont, renderer and export paths extend all seven cases.

## Execution order: one failing tracer at a time

1. **Outlined pixels and bounds.** Add one real export regression proving white glyph interiors
   and colored stroke on a contrasting synthetic background. Watch it fail, then implement
   only enough. Check wide/zero strokes, sharp glyphs and measured ink at fractional/doubled
   scales. Include accents/RTL/emoji; intrinsic-color emoji must not become empty silhouettes.
2. **Boxed pixels.** Add nil-white/transparent/custom background controls with literal pixels,
   then rectangular, rounded and monospaced-box variants. Verify padding does not change
   content origin/maxWidth, rounded corner pixels and full visual bounds. No failure-skipping
   or weakened legacy tests.
3. **Model/background command.** Real selected text plus selected shape/plain text; explicit
   background/reset, new-text default, independent undo and continuous color changes. Test
   active-input/closed/error refusal before state/history changes. Preserve all seven values
   through selection, creation, duplication, editing, serialization and redo.
4. **Native feasibility and integration.** First write a native regression for editable outline
   attributes/new characters and live passive box geometry. Preserve selected ranges and
   programmatically marked text during zoom; mark physical IME as unrun. Add the four native
   choice buttons and truthful Background Color/Reset controls with EN/PT help and AX values.
5. **Privacy and exports.** Paired secret sources plus unmasked positive controls for all seven
   appearances, PNG/JPEG, transformed edges, magnifier and clean representation metadata. Typed
   denial, cancellation and stale paths remain required. Final source masks cover all new ink.
6. **Qualification.** Format, generate/commit project if needed, focused tests, full development
   gate, bilingual native and full-suite checks; Matt Pocock Standards/Spec axes, adversarial
   different-model code/security and fresh source-blind native acceptance. Fix confirmed issues
   within scope. Update docs/version evidence without claiming a new installation.

Exact gate commands retain the current repository toolchain contract:

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development swift test --package-path Packages/RecortiaKit --filter <focused-suite>`

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development scripts/check.sh --unsigned`

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development scripts/e2e.sh --lang all --only <text-scenarios> --unsigned`

## Alternatives and five-year review

Size/color presets challenge whether seven appearances are needed, but do not implement the
approved visual capability. A general rich-text inspector would supply more formatting while
expanding state, input and export obligations. The chosen typed values plus shared stateless
layout and passive native decoration keep a smaller maintenance surface. Reassess only if the
native feasibility check disproves safe composition; do not introduce a second text engine.

Primary references: [Core Text stroke width](https://developer.apple.com/documentation/coretext/kctstrokewidthattributename)
and [NSTextView](https://developer.apple.com/documentation/appkit/nstextview). The advisor ran
no tests/builds/GUI and made no source edits. Its recommendations are design input, not
implementation acceptance. Impeccable's Operate guidance preserves native affordances and
readable state; Tasteskill explicitly excludes application screens.
