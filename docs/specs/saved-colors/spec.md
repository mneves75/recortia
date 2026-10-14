# Saved annotation colors

## Assumptions

The owner's reference-feature request and no-interview instruction authorize this local slice.
One shared palette holds at most 12 distinct opaque sRGB annotation colors; it starts empty.
Saving is explicit and saves only the chosen stroke color, never screenshot pixels, OCR or text.
No synchronization, cloud, automatic recent-color history or system-wide palette modification.
This slice implements saved colors; it does not claim complete predefined text-style parity.

## Choice and rejected alternatives

Use the existing sealed SettingsStore and EditorEnvironment.settings. A bounded domain value
keeps decoding and mutation deterministic. A window-only palette would lose colors on restart;
using the system color panel's shared favorites would change settings outside Recortia's domain.
Neither is appropriate for an explicit Recortia saved-palette feature.

Five years later, native controls, small persisted values and preserved consent matter more than
a palette framework. Add no dependency or parallel settings database.

## Contract and public seams

- `SavedAnnotationPalette`: up to 12 colors, opacity normalized to 255, deduplicated in insertion
  order. An oversized decoded array fails before materializing an unbounded color collection.
- `Preferences.annotationPalette` is optional, so existing v1 blobs decode without losing other
  values. Preferences schema becomes 2 to protect saved colors from an older app's writes.
  Existing sealed side-effect consent stays intact; a palette change does not rotate upload
  consent identity. A newer unsupported schema remains untouched.
- `EditorModel` uses the shared settings store: explicit Save Current Color, apply a saved color
  via existing stroke editing/undo, and remove an explicit selected saved color. Closed editors
  and unsupported future-schema stores reject palette edits; duplicates/full palette cannot save.
  Saving/removing does not alter document, history or any export preference. Applying a saved
  color changes annotation stroke through the existing command path and is undoable.
- Native inspector swatches have HEX labels, accessible names and selected-state indications;
  selection never relies on color alone. Save and removal controls explain disabled states.
  All strings are EN/PT-BR, within the existing scrollable inspector.

## Acceptance

Docs first, then one red/green public seam at a time: bounded value/decoding, v1 reload and
sealed consent preservation, cross-editor palette persistence, apply/undo, denial/closed/duplicate
cases. Real native synthetic controls and bilingual rendering follow; no real user defaults,
permission request, clipboard or network transfer is used in validation. Run the affected full
development gate and independent adversarial review. Physical and stable-release qualification
remain separate. No installation, merge, beta tag or distribution is implied by source work.

Status: implementation in progress; backend regressions pass, native controls await validation.
