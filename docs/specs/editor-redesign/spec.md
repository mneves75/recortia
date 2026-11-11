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
   for private information." FR-06 and RED acceptance require this distinction to stay visible,
   so it is pinned between the tab picker and the form, shown on either tab (review fix 2026-11-10).
5. **Pixel tools** (loupe, ruler, color picker): contents as today; the two unit captions move to
   tooltips, the empty prompts stay.

The always-on Redaction section is removed: the three tools are in the toolbar.

### Image tab, in this order

1. **Size**: canvas size, crop with Reset, output scale, Fit Canvas to Content, Add Margin.
2. **Framing** (pt-BR "Moldura"; `image.background` on the Background picker): today's
   Presentation controls.
3. **Images**: Add Image…, Paste Image, Side by Side, Compare Transparency.
4. **Text & QR**: as today; the chosen text format belongs to the editor and survives switching
   tabs (review fix 2026-11-10).

### Density and copy

- `.controlSize(.small)` on the inspector; grouped form style stays.
- Captions that only explain a control move to `.help`. Captions that report state (mixed values,
  future default, unavailable) or that are required disclosures stay.
- Every string, new or changed, is in `Editor.xcstrings` in English and pt-BR; strings no longer
  used are removed.

## Slice 2 — window toolbar (built 2026-11-10)

Tools and export actions moved from the in-content strip to the window's toolbar, so the title bar
and tools are one native bar that takes the system's current look on each macOS release.

- Mechanism: SwiftUI `.toolbar` on the editor root (`EditorToolbarContent`), bridged into the
  AppKit window with `NSHostingController.sceneBridgingOptions = [.toolbars]`;
  `toolbarStyle = .unified`, `titleVisibility = .hidden`, `title` kept. The window stays the one
  `EditorWindowController` builds; `SpacePolicy`, `AppPresence`, collection behavior, tabbing mode,
  minimum size and sizing rules are untouched. Nothing newer than macOS 15 and no `#available`.
- Order: leading [select, hand, crop] [text, arrow, line, rectangle, ellipse, freehand,
  highlighter, step] [redact] [Effects ▾: blur, pixelate, spotlight, magnifier] [Measure ▾: loupe,
  ruler, color picker]; trailing [undo, redo], a spacer item (bridged as a flexible space), then [Copy, Save ▾, Pin, Drag Out].
  On macOS 27 the spacer keeps Copy out of the undo/redo capsule; it is flexible, so at wide
  windows undo/redo stay beside Measure and the output group sits at the trailing edge, a
  deviation from "undo/redo trailing". A second flexible spacer before undo/redo floated that group
  mid-bar at 1320 pt (a fixed width on a toolbar `Spacer` is ignored), so it was not kept.
- Each item keeps its title, symbol, `.help` and disabled rule, shown icon-only, with identifiers
  `tool.<raw>`, `toolMenu.effects`, `toolMenu.measure`, `toolbar.undo|redo|copy|save|pin|dragOut`.
  A menu button shows its group symbol (`camera.filters`, `level`) and name, or, while one of its
  tools is active, that tool's symbol in the accent color, the value "Selected tool" and a name
  with both group and tool; its menu checks the active tool.
- Bridging facts found on macOS 27.3: a Toggle in a bridged toolbar reports its on/off state as
  its accessibility value, so tool buttons use a button `accessibilityRepresentation` that keeps
  the name, "Selected tool" and Press. A bridged `Menu` ignores `accessibilityLabel` and exposes
  its Label text as an attributed title, so that text carries the name. Bridged items perform
  AXPress but `accessibilityPerformPress()` returns false; tests check the effect.
- The remembered editor size stays the content size: `editor-toolbar` resizes to 1040×640 and
  stores 1040×640 while the frame is 1040×692; `editor-window-size` unchanged and passing.
- E2E: `editor-toolbar` (bilingual) drives the real window: toolbar present and strip gone; at 980
  and 1100 pt every non-space item of `NSToolbar.items` is in `visibleItems` (20 of 20;
  the spacer item is bridged as a flexible space, so `visibleItems` holds 21). A throwaway control
  forcing 600 pt left the window at 832 pt with 17 of 20 visible and the overflow chevron shown,
  so the check can fail.; AX press
  of tools; the real Effects/Measure menus opened through accessibility and chosen inside their
  tracking loop; undo/redo enablement; Copy through the export path; the canvas keeps first
  responder. Editor screenshots render the window's frame view, so they show the toolbar.
- Not verified: macOS 15 and 26 rendering (no such host; groups may draw differently there);
  physical VoiceOver and Full Keyboard Access traversal of the toolbar; customization is off.

## Slice 3 — feature tour and Settings (built 2026-11-11)

As built (the first runs were made on a locked console; see the unlocked run at the end of this
section):

- Tour: one `TourPage` view per step (`tour.page`). Slice 3 measured every page at open and
  opened at the tallest page's height; Slice 4 replaced that with the fixed 580 × 615 pt default
  (see Fit below), because the measurement kept the first frame over the 50 ms budget. Showing
  the shortcuts page notes attention.
- Measured 2026-11-11 00:36–00:40 (offscreen; the console may already have been locked, so an
  unlocked rerun must confirm), en and pt-BR, with the held-shortcut notice shown: window
  content 580×615, page viewport 524, tallest page Assign shortcuts (524). Other pages fill
  49–53% (Welcome), 61% (Compose), 64% (Make the point clear), 67% (capture, recognition), 74%
  (sharing). Deviation: "none leaves more than about a third empty" is not met for Welcome,
  Compose and Make the point clear while macOS holds the shortcuts, because the shortcuts page
  with its notice is much taller than the one-line pages. The window still opens at the tallest
  page and nothing scrolls at the default size.
- Settings: seven tabs (General, Shortcuts, Capture, Export, GitHub, Privacy, Text Recognition);
  Pins is a section of General (`settings.pinOpacity`), Scrolling Capture a section of Capture
  (`settings.automaticScrolling`, `settings.accessibilityStatus`, `settings.accessibilityCheckAgain`);
  panes have no minimum height. Measured at the same time: General 245.5 pt (en), Capture 451,
  Export 378.5 and 418 with JPEG quality; Text Recognition lists every language, 1390.5 pt, as before.
- The scrolling permission message now points to Settings › Capture.
- Open: `window-latency` (same caveat, 00:36–00:41) measured the tour window at 109–119 ms median
  with the measurement and 45 ms without it (budget 50 ms; the editor and a first Settings open already exceed it,
  FP-028). The settings click path and the onboarding/settings reruns could not complete with
  the screen locked; results from a locked console are void.
- Unlocked run (2026-11-11 05:10, `.scratch/logs/final-e2e.log`, at `4f8ec58`): `onboarding`,
  `settings`, `last-window`, `automatic-save-settings`, `editor-toolbar` and `window-latency`
  passed in en and pt-BR. `capture-focus` failed its foreground control in both languages and
  `ocr-qr` one foreground-unchanged check in en while the Mac was in use, so that run is not a
  clean pass; the idle-console run for the release is recorded in `BACKLOG.json`.

### Feature tour

The tour reads like a manual: three paragraphs of up to 90 words per page, in a window whose lower
half is empty on short pages. It also names things the editor no longer has ("the presentation
inspector"). Same seven pages, same flow, same identifiers (`tour.*`), same window; only the copy
and the fit change. Every item is a title and one line. The disclosures stay: solid redaction
versus cosmetic effects, automatic exports running before redaction, uploads leaving the Mac.

English copy (pt-BR follows the terms already in the string catalogs). Corrected 2026-11-11 after a
truth check: Return on the region overlay captures the whole display (a drag commits on release),
exporting leaves annotations editable, and macOS may still hold the default shortcuts:

- **Welcome to Recortia** — unchanged.
- **Start with a capture** — "Choose a capture mode from the Recortia menu-bar icon."
  - Region, display or window: "Drag a region, or press Space to pick a window. Return captures
    the whole display; Escape cancels."
  - Delay and repeat: "Capture with Delay catches menus and temporary states. Repeat Last Region
    captures the same area again."
  - Long pages and existing images: "Scrolling Capture joins frames while you scroll. Open, paste
    or drop a PNG or JPEG to edit it without Screen Recording permission."
- **Make the point clear** — "Annotations stay editable; exports are flattened images."
  - Annotate and adjust: "Add text, arrows, shapes, highlights and numbered steps. The inspector
    shows the options for what you selected."
  - Crop, resize and navigate: "Crop to the relevant area and resize the output. Hold Space and
    drag to pan."
  - Redact with solid masks: "Redact replaces the covered pixels in every export. Blur and
    Pixelate are cosmetic, not secure."
- **Read text and inspect pixels** — "Recognition and pixel inspection run on this Mac."
  - Text recognition and QR codes: "Capture Text (OCR) recognizes text in a region, and the editor
    recognizes it in an open image. QR contents are untrusted; only http and https links open,
    after your click."
  - Loupe and color picker: "Inspect exact pixels and copy a color as HEX or RGB, from one pixel or
    an averaged area."
  - Measure without guessing: "The ruler measures in image pixels and, for captures, in points."
- **Compose and keep references** — "Arrange images and add emphasis without leaving the editor."
  - Multiple images on one canvas: "Add images, then move, resize, reorder or place them side by
    side."
  - Framing and emphasis: "Add a background, padding, rounded corners and a shadow. Spotlight and
    Magnifier draw attention to a detail."
  - Reference pins: "Pin an image to keep it in its own window on every Space. Up to five pins."
- **Choose what leaves the editor** — "Sharing uses a flattened, freshly encoded image."
  - Copy, Save or Drag Out: "All three share the same sanitized image, without hidden layers or
    location and text metadata."
  - Automatic exports are optional: "Automatic copy and save run right after a capture, before any
    redaction. Turn them off before capturing sensitive content."
  - Optional GitHub sharing: "Uploads leave this Mac and are off by default. Redacting or deleting
    later does not remove a remote copy."
  - Closing line: "Reopen this tour from Feature Tour in the menu bar."
- **Assign shortcuts** — "Recortia's default shortcuts are the macOS screenshot ones: ⇧⌘3 for the
  display, ⇧⌘4 for a region and ⇧⌘5 for every capture mode. Change or clear them here, or later in
  Settings."

Fit (as shipped in Slice 4): the window opens at a fixed default content size of 580 × 615 pt,
at which no page scrolls in English or Portuguese, the shortcuts page included while macOS holds
the default shortcuts (`onboarding` checks every page at that size). Nothing is measured when the
window opens. The 540 × 480 minimum stays, the window stays resizable, and the scroll view stays
for larger text sizes and smaller windows.

`docs/specs/feature-discovery/` (spec and reference matrix) is updated in the same change so the
recorded tour copy matches what ships.

### Settings

- Each pane is as tall as its content: the 360 pt minimum height goes, so General no longer shows
  two rows above an empty window.
- Nine tabs become seven: "Pins" (one control) moves into General as its own section, and
  "Scrolling" moves into Capture as its own section. No setting, default, consent flow or stored
  preference changes; `GitHub`, `Privacy` and `Text Recognition` stay as they are.
- Open question for the owner, not a change: in the offscreen screenshots the empty shortcut
  recorders show "Record Shortcut" printed twice, slightly offset. That may be the snapshot path
  and not the real control; it needs one look at the real Settings window before anyone "fixes" it.

## Slice 4 — dark appearance and capture panels (built 2026-11-11)

The app already followed the system appearance; most surfaces had never been rendered dark. This
slice is evidence first, fixes where the evidence showed a defect. No appearance setting was added.

- Dark evidence: every surface below now has a `<light shot>-dark` screenshot next to its light
  one, in en and pt-BR: the menu; the seven Settings panes; shortcuts held by macOS and active;
  the region overlay while dragging (size label) and with its Space hint; the window chooser
  (loading, list); the countdown; a pin with its control strip; the scrolling HUD; the drag chip;
  the replacement sheet; the editor at full size (Image tab, Format tab with a rectangle
  selected, a failure notice and the uploaded-link notice); every tour page at full size.
  Helpers: `ScenarioContext.darkCompanion` (switches the real window, restores light),
  `darkHosted` (a second host for content whose color scheme `E2ESnapshot.host` fixes),
  `darkOverlay`, `E2EActions.darkEditor`.
- Chrome control (`ChromeAppearance`, in `Scenarios+Appearance.swift`), on every light and dark
  rendering of app chrome: median relative luminance of the chrome ≤ 0.10 in dark and ≥ 0.60 in
  light, and in dark no more than 3% of the chrome in near-white fills (luminance ≥ 0.80 in a
  horizontal run of at least 12 pt, measured with the surface over opaque black, so the fill can
  only come from the surface). User content is masked by its view or rectangle: the editor
  canvas, a pin's image, the drag chip's thumbnail. Measured: dark chrome medians 0.013–0.019,
  dark fills 0–0.8%; light medians 0.93–1.00. Surfaces that paint no background of their own (tour,
  menu, chooser, countdown, HUD, sheet, chip) are judged as shown over the window ground, as the
  window draws it. Planted case in `appearance-contrast`: a hosted view with a fixed white
  background rendered dark fails on the fill (100%) and the median (1.000); a fixed black one
  rendered light fails the light floor.
- Two-tone rule, not the chrome control: the region overlay (dim, keyline, size label, hint) draws
  fixed colors over user content; `region-overlay` and `space-window` require its dark rendering to
  be pixel-identical to the light one. Seam markers stay under `appearance-contrast`'s contrast
  bands; selection handles and crop keylines are deliberate white/black marks and were not changed.
- Defect found and fixed: the editor's transparency checkerboard was fixed light (mean luminance
  0.743 under dark chrome). It now uses dark tones in dark appearance (0.22/0.15 white) and repaints
  on appearance change. `appearance-contrast` proves it stays on screen: export bytes are identical
  in light and dark, transparent pixels stay alpha 0 in the export and in a pin, and the color
  picker samples alpha 0 there.
- Capture panels: the window chooser's list is as tall as its rows (41 pt two-line, 24 pt one-line,
  20 pt list insets, as the hosted table lays them out) up to 340 pt, then scrolls; `window-chooser`
  checks the real table with three windows and with twelve. The scrolling HUD reserved a 32 pt
  title-bar band (182 vs 150 pt); its panel now sets `HostingPanel.reservesTitleBarArea = false`
  (the hosting controller's `safeAreaRegions` become empty). Style mask, level, Space behavior and
  key-on-click are asserted unchanged; the HUD panel has no window buttons. `scrolling` renders the
  product's `ScrollUIController.makeHUDPanel()`.
- Panel position: `HostingPanel.present` ran right after `setContent`, before the tracked size
  arrived, so it centred a zero-size frame; AppKit then grew the panel from its top-left corner,
  leaving every tracked panel (chooser, HUD) half its width right of centre (210 pt for the
  chooser). `present` now sizes an unsized panel to its content first
  (`sizeToContentIfUnsized`); `window-chooser` repeats `present`'s arithmetic on the reused panel
  and requires the top edge and centre to hold when the list replaces loading.
- Follow-ups: the tour opens at a fixed 580 × 615 pt (Fit above); `last-window` waits for the
  review's preview before pressing Discard or Accept; an automatic batch's single failure is the
  editor notice `automaticExportFailed`, worded as the alert ("An automatic export step failed. The
  disk is full." / "Uma etapa da exportação automática falhou. O disco está cheio."), while a
  failed manual save still says nothing was saved; the editor's import-failure text is the alert's
  detail (pt-BR "Apenas imagens…"), and ten Editor-table keys were removed.
- Not verified in this slice's own runs: anything foreground-dependent (the console was locked
  for every one of them). The later unlocked run recorded under Slice 3 covered `last-window`, the
  Settings and automatic-save click paths and `window-latency`. Still not verified: a key-window
  render of these surfaces;
  real `NSVisualEffectView` materials, which do not render through `cacheDisplay`; macOS 15 and 26;
  Increase Contrast and Reduce Transparency in dark.
- Noticed and left: the window chooser still has an empty title-bar band above its heading (the
  same safe-area inset the HUD had); it was not in this slice's brief.

## Later slices

Capture overlays, HUDs and pins, starting from the finished editor as the visual reference.

## Not in scope

Model, export, privacy or persistence changes; new features; moving commands into the menu bar.
