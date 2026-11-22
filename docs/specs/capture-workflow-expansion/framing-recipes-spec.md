# Named framing recipes

**Requirements** FR-13, EDIT-01, EXP-01, RED-01 and UX-01. This is the first framing slice in
the [capture workflow plan](plan.md). Border and watermark are a separate slice.

## Behavior

- Save the current framing as a named recipe in the editor's Image inspector. Keep up to 12
  recipes. Store a stable identifier, a name and the existing typed `Presentation` value.
- Apply a recipe in one undoable document edit, including while Output Preview is open. Undo and
  redo affect the open document only. Rename or delete a recipe without editing any document.
- Keep the existing one-default control. To make a recipe the default, apply it and use
  Save as Default Framing. The default stores a copy of the framing. Renaming or deleting the
  recipe therefore preserves the default. Reset clears the default and keeps the recipes.
- A recipe holds style values only. It contains no screenshot pixels, bookmark, file reference
  or network setting. Applying a recipe changes presentation and never moves a secure mask.

With twelve 64-byte names containing escaped characters and detailed gradient and shadow values,
the sorted preferences JSON was 6,565 bytes. The same preferences without recipes used 380 bytes.

## Admission

Use the existing settings store to admit persisted and edited values. An absent list means no
recipes and retains the previous preference encoding. Trim and normalize Unicode names. Reject
blank names, controls, line breaks, names over 64 UTF-8 bytes and case-insensitive duplicates.
Use the existing framing validation for style admission. Retain the earliest valid entry when
persisted entries have duplicate IDs or names. Drop invalid and excess entries. A stale recipe
cannot apply, rename or delete a different recipe. A refused name leaves the form open with an
accessible reason.

## Acceptance

- Save, apply, rename and delete through normal editor controls in English and Brazilian
  Portuguese. `framing-presets` checks one undo and redo, an admitted no-op, duplicate save and
  rename, blank names, and the difference between 64 and 65 UTF-8 bytes. Renaming or deleting a
  recipe preserves the applied framing and the saved default. Reusing a deleted name leaves
  the former identifier invalid for apply, rename and delete.
- Verify old preferences still decode and seal, named values persist across reload, and
  applying or changing defaults preserves already-open documents. A newly captured document
  receives the explicit default. Imported documents retain the current import behavior.
- Use the existing render and pixel gates to compare preview and export. Retain the RED
  controls for presentation changes and secure masks. Use `cccc` before writing tests and
  honor the owner's complexity threshold. Dedicated VoiceOver and installed-app checks follow
  the unchanged release procedure.
