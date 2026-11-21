# Design direction — program 2026-11 (T1c editor, T2 surfaces)

Source: the 0.14 baseline screenshots (`./init.sh e2e --lang all`, 2026-11-20) judged by eye, and
the editor spike on macOS 26 containers. The owner's complaint was that the 0.14 redesign did not
improve the look. That redesign changed structure and kept every control. This one removes controls
and gives each surface a single clear primary action.

## What is wrong today

1. **Everything has the same weight.** Every button is a grey bezel: Continue, Accept, Choose…,
   Duplicate and Delete look alike. No surface has a default action.
2. **The same command lives in several places.** Delete appears in the inspector, the sidebar
   footer, the context menu and on the keyboard. Duplicate appears in the inspector and the menu.
   Six unlabelled alignment buttons take a whole inspector row.
3. **The inspector shows everything at once.** A selected text shows X, Y, Width, Height, Edit
   Text, Duplicate, Delete, Arrange, six alignment buttons, a Color capsule, two unlabelled +/−
   buttons, a Fill switch, a separate Fill Color well, Opacity, Text Size and seven "Aa" tiles.
   That is about 30 controls for one word of text.
4. **Unclear controls.** The +/− buttons save and remove palette colours. The seven "Aa" tiles
   encode font design and decoration in one grid. "Fill" and "Fill Color" are two rows for one
   property.
5. **Helper text and taglines:** the onboarding subtitle, "Complete capture." on a complete
   review, the seam paragraph, the Export footer paragraph.
6. **Floating surfaces look like settings.** The pin's control strip sits permanently under the
   image as a row of grey buttons and a slider.

The base is sound: system text styles throughout, no hard-coded chrome colours, native toolbar.

## Principles

- **One primary action per surface.** It uses `.keyboardShortcut(.defaultAction)` and the
  prominent style: Continue, Accept, Done. Destructive actions (Discard, Delete) use the destructive
  role and never sit next to the primary action with equal weight.
- **One place per command.** The toolbar or the inspector, plus the menu bar (always) and the
  context menu (mirrors the menu). The inspector keeps only properties, never commands that already
  have a menu item.
- **Progressive disclosure.** Rarely used properties (position, size, alignment) sit in a
  collapsed disclosure group, which remembers its state per session.
- **No helper text** unless a requirement makes it mandatory (FR-06 cosmetic-effect warning; FR-07
  automatic-export disclosure). Mandatory text is one short sentence.
- **System look on macOS 26.** Standard containers, the system toolbar and system materials where
  rendering can be verified (see "Materials").

## Tokens (one set, in one file: `RecortiaApp/App/DesignTokens.swift`)

| Token | Value | Use |
|---|---|---|
| `radius.control` | 6 | swatches, tiles, small wells |
| `radius.container` | 10 | grouped boxes, notices, panels |
| `radius.window` | system | never hard-coded |
| `space.xs/s/m/l` | 4 / 8 / 12 / 20 | the only paddings and spacings |
| `notice` | one style: `.background(.quaternary, in: radius.container)`, SF symbol + one line | every inline notice (editor, review, settings) |
| `selection` | system accent | one selection idiom everywhere (list rows, tiles, swatches) |

Every literal radius or padding outside this file is replaced by a token.

## Editor (T1c)

- **Containers:** an `NSSplitViewController` with sidebar, canvas and inspector items (spike
  structure), toggled from View › Show/Hide Sidebar (⌃⌘S) and Show/Hide Inspector (⌃⌘I). The
  commands are enabled only for a key editor window (spike F7). The cosmetic-effect warning (FR-06)
  stays visible while Blur or Pixelate is in use even with the inspector collapsed: it moves into
  the status bar as one line with a warning symbol (spike F1).
- **Toolbar groups (left to right):** Select · Hand | Crop | Text · Arrow · Line · Rectangle ·
  Ellipse · Pen · Highlighter · Step | Redact · Effects ▾ | Measure ▾ | Undo · Redo — then
  flexible space — Copy · Save ▾ | Pin · Drag. Use `ToolbarSpacer` (macOS 26) between groups
  instead of `Spacer` hacks. Every item stays visible at 980 pt (AGENTS.md).
- **Inspector, Format tab, top to bottom:**
  1. Header: the object's name (editable title field), no separate "Edit Text" button (double-click
     and Return already edit; keep the Edit menu item).
  2. **Appearance** group: Color (well + the saved palette as a row of swatches; "+" saves the
     current colour; removing is a swatch context-menu item), Fill (one row: switch + well,
     the well disabled while off), Line width, Opacity.
  3. **Text** group (text only): Font (pop-up: System, Rounded, Serif, Monospaced), Style
     (segmented: Plain, Outline, Box, Rounded box), Size (stepper field). It replaces the seven
     "Aa" tiles; the boxed-background controls appear only for Box styles.
  4. **Position and size** disclosure, collapsed by default: X, Y, Width, Height.
  - Removed from the inspector: Duplicate, Delete, Arrange, the alignment row. They live in the
    Arrange menu (new top-level menu: Bring Forward, Send Backward, Bring to Front, Send to Back,
    Align ▸ six items, Duplicate) and the context menu, Delete in Edit.
- **Image tab:** Background (None, Colour, Gradient: neutral graphite default, replacing the
  blue-to-purple gradient), Padding, Corner radius, Shadow, Canvas size. Same group style.
- **Sidebar:** object list with type symbols; reorder by drag; the footer keeps only the object
  count. Up/down and trash buttons go (menu and keyboard cover them).
- **Canvas:** the image sits on the canvas background with a 1-pt separator stroke in
  `separatorColor` and the system window shadow radius, so a white screenshot never merges into
  a light canvas. Keyboard focus shows the system focus ring around the canvas.
- **Status bar:** size · zoom pop-up · (warning when cosmetic effects exist). Notices use the one
  `notice` style; two-line notices are never clipped (spike F2: no line cap on required text).

## Other surfaces (T2)

- **Scrolling review:** title "Scrolling Capture"; the status line only when partial (with the
  reason); size as secondary text; Discard (destructive, left) and Accept (default, prominent,
  right). The seam explanation becomes the preview's accessibility hint, not visible text.
- **Pins:** the control strip is hidden until the pointer enters the pin, then floats over the
  bottom edge (rounded `radius.container`, regular material if snapshots render it, else
  `windowBackgroundColor` at 92%). Controls: close, copy, drag, zoom (− 100% +), opacity as a
  pop-up (100/75/50/25%) instead of a slider.
- **Onboarding:** drop the subtitle on every page; page dots instead of "Step 3 of 7";
  Continue is the default prominent button; Skip becomes a plain text button. Pages that only
  list features merge: target five pages in the fixed 580 × 615 pt window (AGENTS.md).
- **Settings:** each pane keeps grouped `Form` rows. Footers are deleted except the FR-07
  disclosure, cut to one sentence: "Runs right after a capture, before you edit or redact."
  "Copy Image always places a PNG on the clipboard" moves into the Format row's help tag.
- **HUDs, chooser, drag chip:** `radius.container`, `space.m` padding, the same material rule as
  pins, SF symbols at `.title3`.
- **Alerts:** editor-scoped messages become sheets on the editor window; app-level messages stay
  alerts (plan). Informational alerts that duplicate an inline notice are removed.

## Materials and verification

E2E screenshots use `cacheDisplay`, which drops vibrancy: in the spike, sidebar icons, slider
tracks and colour wells vanished. Until a real window capture is possible (Screen Recording for
the E2E app is an owner TCC step), the editor's sidebar and inspector use the `.default`
split-item behaviour over `windowBackgroundColor`, not the glass sidebar material. Every surface
then renders in screenshots exactly as on screen, and `ChromeAppearance` stays a valid judge. The
toolbar keeps the system glass, which renders in the frame-view screenshots. Floating panels use
a material only when an E2E screenshot proves the controls render; the implementer measures it
and records the result here.

Acceptance for each surface: light and dark screenshots in both languages judged by eye by the
coordinator; `ChromeAppearance` passes; 980 pt toolbar check; no clipped text in pt-BR; VoiceOver
labels on every icon-only control.
