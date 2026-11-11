# Editor redesign — spec

Owner request (2026-11-10): the editor's UI/UX and visuals are not good enough. Decisions taken
with the owner the same day: one finished slice first (inspector, then the window toolbar), the
deployment target stays macOS 15.0, and standard system controls carry the look (no custom glass
effects, no availability branches). FP-045 tracks the work.

## Diagnosis

Styling is already consistent (semantic fonts, system colors). The defect is structure: the
inspector is one long scroll that mixes four scopes — properties of the selection, defaults of the
active tool, settings of the whole image, and commands — and shows most of them all the time. It
also repeats the toolbar (a Redaction section that only re-launches three tools), uses columns of
checkmark buttons for one-of-N choices, and spends rows on helper text.

## Rule

The inspector shows the properties of what the person is working on, and nothing else. Every
control that stays must apply to the current selection, the current tool, or the image.

## Slice 1 — inspector

### Two tabs

A segmented picker at the top (`inspector.tab`): **Format** and **Image**.

- Format has content when the selection is not empty, or the tool is one of: text, arrow, line,
  rectangle, ellipse, freehand, highlighter, step, redact, blur, pixelate, loupe, ruler, color
  picker.
- The shown tab is the person's manual choice, or — when they have not chosen since the selection
  or tool last changed — Format when it has content and Image otherwise. A selection or tool change
  clears the manual choice. So: click an object, see its format; click empty canvas with the
  Select tool, see the image settings.
- Format with no content shows one line: "Select an object or choose a tool."

### Format tab, in this order

1. **Object** (selection not empty). Header: the object's label, or "N objects".
   - X, Y, Width, Height as a 2×2 grid of labelled fields (`frame.x`, `frame.y`, `frame.width`,
     `frame.height`), same commit-on-Return and aspect-ratio behaviour as today.
   - The kind's own controls, unchanged in behaviour: layer opacity and scale; redaction color;
     obfuscation strength; spotlight dimming; magnifier source; Edit Text.
   - One row: Duplicate, Delete, Arrange menu. One row: the alignment buttons (moved here from
     Composition; they act on the selection).
2. **Style** (a style-using tool is active or an annotation is selected).
   - Color well.
   - Saved colors directly under it as a grid of swatches only: no hex text, no caption. Each
     swatch keeps `palette.apply.<HEX>`, its hex as accessibility label and tooltip, "Selected" as
     accessibility value, and the Remove context menu. The selected swatch shows a ring that does
     not depend on the swatch color. After the swatches: a "+" button (`palette.save`) and a "−"
     button (`palette.remove`) with their current labels as accessibility labels and tooltips.
     The "newer preferences are protected" line stays, shown only in that state.
   - Only the controls the kinds in play use. "Kinds in play" are the selected annotations' kinds,
     or the active tool's kind when no annotation is selected; with several kinds, show the union.
     Derive which kinds use fill, line width and text size from the renderer, not from this list:
     fill (`style.fill`, with its color), line width (`style.lineWidth`), opacity, text size
     (`style.textSize`, a labelled value with a stepper). Never hide a control that changes a
     selected object.
   - Boxed-text background controls keep their identifiers and rules (`textBackground.*`).
   - Arrow shape (arrow tool or arrows selected): Straight and Curved as two side-by-side toggle
     buttons (`arrow.straight`, `arrow.curved`), then `arrow.mixed`, `arrow.futureDefault` and the
     bend fields as today.
   - Text style (text tool or text selected): a grid of preview tiles, one per `TextAppearance`,
     each showing "Aa" in that appearance, with `textAppearance.<raw>`, the name as accessibility
     label and tooltip, and "Selected" as accessibility value.
   - Renumber Steps only when the step tool is active or a step is selected.
3. **Redaction** (redact tool active or a redaction selected): color well, and one caption:
   "Covered pixels are replaced in every export. Other copies and earlier exports are not
   changed."
4. **Cosmetic effect** (blur or pixelate tool active, or one selected): the warning label
   (`redaction.cosmeticWarning`): "Cosmetic, not secure: text can remain recoverable. Use Redact
   for private information." FR-06 and RED acceptance require this distinction to stay visible.
5. **Pixel tools** (loupe, ruler, color picker): contents as today; the two unit captions move to
   tooltips, the empty prompts stay.

The always-on Redaction section is removed: the three tools are in the toolbar.

### Image tab, in this order

1. **Size**: canvas size, crop with Reset, output scale, Fit Canvas to Content, Add Margin.
2. **Background** (`image.background` on the picker): today's Presentation controls.
3. **Images**: Add Image…, Paste Image, Side by Side, Compare Transparency.
4. **Text & QR**: as today.

### Density and copy

- `.controlSize(.small)` on the inspector; grouped form style stays.
- Captions that only explain a control move to `.help`. Captions that report state (mixed values,
  future default, unavailable) or that are required disclosures stay.
- Every string, new or changed, is in `Editor.xcstrings` in English and pt-BR; strings no longer
  used are removed.

## Slice 2 — window toolbar (not started)

Move tools and export actions from the in-content strip to the window's toolbar, so the title bar
and tools are one native bar that takes the system's current look on each macOS release.

- Mechanism: SwiftUI `.toolbar` on the editor root, bridged into the AppKit window with
  `NSHostingController.sceneBridgingOptions = [.toolbars, .title]` (macOS 14+). The window stays
  the AppKit window `EditorWindowController` builds; `SpacePolicy` and `AppPresence` are untouched.
- Probe (2026-11-10, macOS 27.3, standalone script, not in the repository): an offscreen titled
  window with a bridged toolbar of ten toggles and two buttons renders its title, groups and
  selected state through `cacheDisplay` of the window's frame view (`contentView.superview`), in
  light and dark. So E2E can keep the toolbar in editor screenshots by rendering the frame view
  instead of the content view. The window is not key in that render (grey window buttons).
- Step A: the same tools, groups, undo/redo and export actions as today, as toolbar items (tools
  centred, undo/redo and export trailing), each with its title, symbol and `.help`. Snapshot at the
  default and the minimum window width, light and dark, both languages.
- Step B, decided on Step A's screenshots: if the tools do not fit at the default width, fold the
  occasional ones into menu buttons that show the active tool (cosmetic effects; spotlight and
  magnifier; loupe, ruler and color picker) rather than letting the system overflow menu hide them.

## Later slices

Settings and onboarding; capture overlays, HUDs and pins. Each starts from the finished editor as
the visual reference.

## Not in scope

Model, export, privacy or persistence changes; new features; moving commands into the menu bar.
