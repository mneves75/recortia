# Output border and text watermark

**Requirements** FR-13, EDIT-01, EXP-01, RED-01, RED-02 and UX-01. This slice implements the
border and text watermark from the [capture workflow plan](plan.md).

## Behavior

- Set or remove a border from the Image inspector. The border uses a solid color and a
  width of 1–64 document units. Draw it inside the final output bounds without changing
  output dimensions. Never stroke an edge twice.
- Set or remove a one-line text watermark. Use four corner positions and center. Provide
  rotation from −180° to 180° and opacity from 5% to 100%. The style uses light text with a
  dark outline. Fit the rotated painted bounds to the output, with a margin at the selected
  anchor. Very small outputs may render only a small watermark.
- Trim boundary whitespace and normalize Unicode. Refuse blank text, embedded line breaks,
  control characters and more than 256 UTF-8 bytes. Clearing the watermark is a separate
  action. Each accepted change follows ordinary editor undo and redo.
- Draw decorations after secure replacement and ordinary composition, before clean encoding.
  Output Preview and all export sinks use this renderer. The edit canvas keeps its existing
  content geometry. Decorations hold text and style only and cannot sample pixels.
- Omit disabled values from serialized presentation data so older documents, preferences and
  signed settings remain compatible. The existing framing default and named recipe paths
  carry the presentation value. Applying either remains an explicit operation.

## Verification

Use the existing renderer and export seams. Check border pixels, opacity, bounds and
dimensions. Use an asymmetric rotated watermark at a corner and Unicode text. Compare
sanitized output for two sources differing only under the same mask. Check malformed text
and non-finite geometry, absence of extra encoded representations, editor undo and redo,
and real Preview in EN/pt-BR. Run the dedicated physical qualification through the existing
release procedure.
