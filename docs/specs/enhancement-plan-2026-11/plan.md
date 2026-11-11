# Enhancement plan 2026-11 — proposal

Owner request (2026-11-11): study two installed reference screenshot utilities, take their best
practices, optimizations and macOS conveniences, and produce a detailed implementation plan to
enhance Recortia.

**Status: proposal.** Nothing here is approved work and none of it is in 0.14.0. Under AGENTS.md
each item is proposed first; items in class B need a recorded decision before any code. This
document extends `docs/specs/feature-discovery/reference-matrix.md` (capability inventory of
2026-10-14), which stays the per-capability status record.

## Evidence and boundary

Two reference utilities installed on the owner's Mac were examined on 2026-11-11: **reference A**,
a full capture suite, and **reference B**, a small single-purpose utility. Per AGENTS.md they are
not named here.

Each claim below carries its source:

- **[M]** bundle metadata read from the installed apps: `Info.plist`, code-signing entitlements,
  linked system frameworks, extension declarations, resource file names.
- **[P]** the vendors' public feature and automation pages, fetched 2026-11-11. These are leads,
  not measurements: one page describes a newer version than the installed bundle.
- **[R]** Recortia's own code and documents at `4f8ec58`.
- **[I]** inference from the above; verify before relying on it.

Not done, on purpose: neither app was launched or driven, no binary was disassembled or
string-dumped, and no asset, sound, layout or wording was copied. Only ideas and interaction
patterns are taken. Vendor timing claims are not Recortia measurements and set no budget here.

## What the references show

| Observation | Source | Recortia today |
|---|---|---|
| Both declare PNG/JPEG document types, so Finder's Open With, drag onto the icon and `open -a` work | [M] | Declares no document types; images enter only by menu, paste or drop on an open editor [R] |
| Both expose a URL scheme; A documents 19 commands, each showing its normal UI | [M][P] | None; FR-16 deferred [R] |
| A ships two share extensions that accept images ("annotate", "pin") | [M] | None [R] |
| A has its own editable project type with Quick Look preview and thumbnail extensions | [M] | In-memory documents, flattened exports only [R] |
| A is not sandboxed; B is sandboxed with user-selected file access, network client and print | [M] | Not sandboxed; ADR-002 records why (automatic scrolling needs Accessibility) [R] |
| A links a third-party crash reporter and holds push, camera and microphone entitlements | [M] | No telemetry SDK, no audio, no camera, by contract [R] |
| A ships several capture and countdown sounds | [M] | No sound feedback [R] |
| B's whole bundle is under 7 MB with no embedded frameworks | [M] | Comparable approach: system frameworks plus one shortcut package [R] |
| Selection aids during region capture: frozen screen, magnifier at the crosshair, arrow-key nudging, forced square, locked aspect | [P] | Overlay handles Escape, Return and Space only; size label only [R] |
| A floating quick-action thumbnail after each capture (copy, save, edit, drag out, dismiss) | [P] | The editor window opens after every capture [R] |
| Pins that stay above other windows, with a click-through mode | [P] | Normal-level pins by ADR-007 [R] |
| Colour tools: more formats, text-colour sampling, contrast checking | [P] | HEX and RGB, 1×1/3×3/5×5 sampling [R] |
| Framing: saved presets, aspect ratios, alignment, automatic balancing of margins, image backgrounds | [P] | Solid or gradient background, uniform padding, radius, shadow [R] |
| Filename templates | [P] | Fixed timestamp name (`ExportFilename.make`) [R] |
| Text-aware tools: highlighter sized to the text line, hiding text only | [P] | Free-form highlighter; no text-aware marks [R] |
| Restore the last closed capture; searchable history | [P] | Nothing retained after close, by contract [R] |

## Classification

Every candidate is placed in one of three classes before it is ranked.

### Class A — fits an approved requirement

These extend FR-01…FR-14 without a new permission, entitlement, persistence or network path.

| ID | Enhancement | FR | Size |
|---|---|---|---|
| A-1 | Editor windows named after their content | FR-01, FR-04 | S |
| A-2 | Open With, drag onto the icon, `open -a` for PNG and JPEG | FR-03 | S |
| A-3 | Menu-bar commands for everything the editor does | FR-14 | M |
| A-4 | Selection precision: nudge, constrain, aspect lock, window-edge snapping | FR-02 | M |
| A-5 | Frozen-frame selection with a magnifier at the crosshair | FR-02 | L |
| A-6 | One-click secure redaction of a recognized text line; text-aware highlighter | FR-06, FR-08 | L |
| A-7 | Colour formats, text-colour sampling and contrast checking | FR-11 | M |
| A-8 | Framing presets, aspect ratios, alignment, balanced margins | FR-13 | M |
| A-9 | Filename templates | FR-07 | S |
| A-10 | Editor gestures: Option-drag to duplicate, crop aspect presets, rotate and flip | FR-04 | M |
| A-11 | Arrowhead styles and freehand smoothing | FR-05 | M |
| A-12 | Optional capture sound | FR-01 | S |
| A-13 | Measured latency baseline, then pre-built windows (FP-028) | FR-14 | M |

### Class B — needs a fresh owner decision first

| ID | Enhancement | Why it needs a decision |
|---|---|---|
| B-1 | Quick-action thumbnail after capture | Changes the capture-completion contract; where an un-acted capture lives and when it is discarded is a privacy decision (new ADR) |
| B-2 | Shortcuts actions, then a URL scheme | FR-16 is deferred pending separate approval; another process could trigger capture UI |
| B-3 | Pins that stay on top, with click-through | Reverses ADR-007 (pins are normal-level so window switchers list them) |
| B-4 | Share extension ("open in Recortia", "pin") | New extension target and an app group to hand the image over |
| B-5 | Signed in-app updater | FP-024 is blocked on the signing-key custody decision |
| B-6 | Restore the last closed capture, in memory only | Keeps pixels after the person closed them; must be bounded and approved |
| B-7 | Element-level selection snapping | Would use Accessibility for capture, a new use of that permission |
| B-8 | Editable project files with Quick Look | Persists source pixels under redactions; needs a threat-model decision |
| B-9 | Further formats (HEIC), horizontal scrolling capture, printing, another upload provider | Each changes an approved contract (FR-07, FR-10, FR-15) |
| B-10 | Local-only diagnostics file the person can attach to an issue | Must be proven network-free and opt-in to coexist with "no telemetry" |

### Class C — excluded by AGENTS.md

Screen recording, GIF or video, audio, camera, keystroke display; cloud accounts, comments and push
notifications; a screenshot history archive; telemetry or crash-reporting SDKs; licence or update
checks at launch; private or temporary-exception system service names. The references' evidence
for these ([M]: camera, microphone and push entitlements, crash-reporter framework, bundled video
encoders; [P]: one month of history, cloud) is recorded so the question does not have to be
reopened.

## Detailed plan — class A

Each item lists what the person gets, the design, where it lands, how it is proved, and the risk.
Sizes: S is one short agent run; M is one slice like the 0.14 inspector; L is several slices.

### A-1 Editor windows named after their content (S)

- **Gets:** window switchers, Mission Control and the Window menu show "Capture 14:32", the opened
  file's name, or "Scrolling capture 14:32" instead of several identical "Recortia Editor" entries.
- **Design:** `EditorWindowController` sets `window.title` from the document's origin (capture
  time, imported file name without path, pasted image). The title stays hidden in the toolbar.
  For an opened file, `representedURL` gives the standard proxy icon only if the person saves back
  to that file; otherwise no proxy, so nothing implies the original was modified.
- **Lands:** `RecortiaApp/Editor/EditorWindowManager.swift`, `Editor.xcstrings`.
- **Proof:** bilingual `window-presence` gains title checks for three origins; no path or
  user-content text in a title beyond the file's own name.
- **Risk:** a file name is user content shown in system UI; it already appears in Finder, so the
  exposure is unchanged.

### A-2 Open With, drag onto the icon, `open -a` (S)

- **Gets:** right-click an image in Finder and open it in Recortia; drop an image on the icon.
- **Design:** declare PNG and JPEG document types (role Editor, rank Alternate so Recortia never
  becomes the default handler by itself). Handle `application(_:open:)` in `AppDelegate` by
  passing each URL to the existing `ImageImporter.admit`, which already bounds size and count.
  A cold launch by open event shows the editor, not onboarding or Settings (`LaunchKind`).
- **Lands:** `project.yml` (Info properties), `RecortiaApp/App/RecortiaApp.swift`,
  `LaunchKind.swift`.
- **Proof:** `import-admission` extended with open events: one file, several files, an oversized
  file, a non-image, and an open event during first-run onboarding. Unit guard on admission count.
- **Risk:** many files opened at once; admission already refuses beyond its limit, and the
  refusal must be reported once, not per file.

### A-3 Menu-bar commands for the editor (M)

- **Gets:** every editor action is in the menu bar with its shortcut, so shortcuts are
  discoverable, VoiceOver users have a command list, and the toolbar can be hidden.
- **Today:** the app defines only Settings in its commands; the canvas handles Undo, Redo,
  Duplicate, Select All and zoom itself in `performKeyEquivalent` [R].
- **Design:** File (Open Image…, Paste Image, Save…, Save to Preferred Folder, Close), Edit (Undo,
  Redo, Duplicate, Delete, Select All), View (zoom commands, Show Output Preview, inspector tab),
  Tools (every tool, checked when active, with its single-key shortcut shown), Arrange (order,
  alignment), Window. Commands act on the key editor and are disabled without one. The canvas
  keeps its key handling during text composition; menu items must not steal single-key tool
  shortcuts while a text field or marked text has focus.
- **Lands:** `RecortiaApp/App/RecortiaApp.swift` or an AppKit main menu built beside
  `CaptureMenu.swift`, `EditorWindowManager.swift`.
- **Proof:** new bilingual `editor-menu` scenario: each item exists, enables with an editor,
  performs the same model change as the toolbar, and typing a tool's letter into an annotation
  still types the letter (`canvas-focus` extended).
- **Risk:** single-key equivalents in menus intercept typing. Mitigation: show them as hints in
  the title or validate them off while editing text; decide by experiment before building.

### A-4 Selection precision without new permissions (M)

- **Gets:** after dragging a region: arrow keys move it by 1 px (Shift by 10), Option-arrows
  resize it, Shift while dragging forces a square, a remembered aspect lock, and edges that snap to
  window frames.
- **Design:** the overlay keeps a selection after mouse-up until Return or a second click, behind
  a setting that defaults to today's behaviour (release captures at once), so muscle memory is not
  broken. Window frames come from the ScreenCaptureKit window list the chooser already loads; no
  Accessibility use. Space and Return keep their current meaning before a drag begins.
- **Lands:** `RecortiaApp/Capture/RegionOverlay.swift`, `CaptureUIController.swift`,
  `Features/CaptureCoordinator.swift` (geometry only), Settings › Capture.
- **Proof:** `capture` scenarios for each key, in typed `DesktopSpace` geometry tests (GEO), across
  two displays with different scales; `capture-focus` still passes, since the overlay must stay
  nonactivating.
- **Risk:** changing when capture commits. The default stays as it is; the adjustable mode is
  opt-in.

### A-5 Frozen-frame selection with a magnifier (L)

- **Gets:** the screen stops while selecting, so menus and hover states can be captured, and a
  magnifier at the crosshair shows the exact pixel and its coordinates.
- **Design:** on entering region capture, take one frame of each display through the existing
  capture service into `ImageStore` (the only holder of raw pixels), show it in the overlay, and
  crop the result from that frame instead of capturing again. The frame is discarded on cancel,
  commit, or a timeout, and never leaves `ImageStore`. The magnifier samples that frame, so it
  needs no second capture path. Opt-in in Settings › Capture at first.
- **Lands:** `MacPlatform/ScreenCaptureService.swift`, `Imaging/ImageStore`, `RegionOverlay.swift`.
- **Proof:** RED and PRIV families: the frozen frame is released on every exit path (cancel,
  Escape, display change, sleep, timeout) with a memory-budget assertion; the captured crop equals
  the frozen pixels; the overlay itself is never in the result.
- **Risk:** the largest in class A. It holds full-display pixels before the person has chosen a
  region, and adds latency before the overlay appears. Build it only after A-13 gives a measured
  baseline, and keep the live overlay as the default until the frozen path is at least as fast.

### A-6 One-click secure redaction of a text line (L)

- **Gets:** with the Redact tool, clicking a line of text covers exactly that line with a solid
  mask; the highlighter can size itself to the line it is dragged over.
- **Why this one matters:** it applies the references' text-aware idea [P] to Recortia's own
  promise. Their text hiding is cosmetic; this produces the same source-pixel replacement as a
  hand-drawn redaction.
- **Design:** run the existing on-device recognition once per document revision, off the main
  actor, keep line boxes only (not the text) as transient editor state bound to the revision, and
  hit-test clicks against them. The mask is an ordinary `Mask`, so export, undo and the privacy
  epoch are unchanged. The UI never says text was "detected" or "found": it offers boxes to click,
  and says nothing about what it did not find.
- **Lands:** `Features/EditorModel+Recognition.swift`, `EditorModel+Gestures.swift`,
  `Imaging/TextRecognizer.swift`, inspector Format tab.
- **Proof:** RED family with planted controls: a clicked line is fully covered in every export at
  every scale; a line whose box is stale after an edit is refused; recognition results from an
  older revision are never applied. Bilingual `redaction` scenario. Acceptance wording check: no
  string claims detection of secrets.
- **Risk:** a box smaller than the glyphs would leave slivers. Masks are outset to whole pixels
  and the planted control measures leftover text pixels.

### A-7 Colour formats and contrast (M)

- **Gets:** copy a colour as HEX, RGB, HSL or OKLCH; sample the text colour of an area; pick two
  colours and read their contrast ratio.
- **Design:** formats are pure functions over the existing sRGB sample. Contrast shows the WCAG 2
  ratio with its AA/AAA thresholds; a perceptual contrast value, if added, is labelled as its own
  measure and never as a WCAG level (the matrix already records this constraint).
- **Lands:** `Features/EditorModel+PixelTools.swift`, `Domain/Color.swift`, inspector pixel tools.
- **Proof:** unit tests against published reference values for each conversion and for the
  contrast formula; `pixel-tools` scenario in both languages.
- **Risk:** low. Wide-gamut captures are still reported in sRGB, as today, and the UI says so.

### A-8 Framing presets and balance (M)

- **Gets:** save a framing as a preset and reapply it; choose an output aspect ratio; align the
  image inside the frame; "balance" trims uneven margins so the content is centred.
- **Design:** presets are a small bounded list in sealed preferences, like saved colours.
  Balancing measures the uniform border of the sanitized render and adjusts padding; it never
  reads raw pixels.
- **Lands:** `Domain/Document.swift` (`Presentation`), `Imaging/RenderEffects`, inspector Image tab,
  `SettingsStore`.
- **Proof:** COMP and RED families: every preset renders identically through copy, save, drag and
  pin; balancing on a redacted image uses post-redaction pixels only.
- **Risk:** a new persisted field. Stored as an optional so older preference blobs and seals
  survive, as `keepsRunningInMenuBarChoice` does.

### A-9 Filename templates (S)

- **Gets:** choose how saved files are named: date, time, a counter, a fixed prefix.
- **Design:** a template with a closed set of tokens, validated when entered in Settings › Export
  and rendered by `ExportFilename.make`. No token carries window titles, app names or recognized
  text: those are captured content and would leak into file names.
- **Proof:** unit tests for every token, illegal characters, collisions and very long prefixes;
  `automatic-save-settings` extended.
- **Risk:** low; exclusive creation and the replacement prompt already handle collisions.

### A-10 Editor gestures (M)

Option-drag duplicates a selection; crop gains aspect presets and snaps to image edges; rotate by
90° and flip. Rotation must transform masks with their layer so a redaction never drifts off its
pixels (RED family with a planted control). **Lands:** `Features/EditorModel+Gestures.swift`,
`Domain/AffineMap.swift`. **Risk:** rotation of secure masks; fail closed as mask mapping does now.

### A-11 Arrowheads and smoothing (M)

Three more arrowhead styles inside the existing arrow kind (`ArrowLayout` owns the painted ink, so
selection and export stay in step); optional smoothing of freehand strokes at commit, never during
the drag. **Proof:** `curved-arrows` and `annotations` extended; pixel comparison of selection,
canvas and export. **Risk:** low.

### A-12 Optional capture sound (S)

One short sound on a completed capture, off by default, and silent when the system's interface
sound effects are off. The sound is an original asset or a system sound, never a copied one.
**Proof:** unit test on the decision; no E2E sound output.

### A-13 Latency: measure, then pre-build (M)

- **Today:** FP-028 records that the editor's and Settings' first frames exceed the 50 ms budget
  and that a fix needs pre-built windows [R]. In 0.14 the tour had to drop a measurement step to
  stay inside the same budget.
- **Step 1, measure:** signposts for shortcut-to-overlay, release-to-editor-first-frame and
  copy-to-pasteboard, read by the existing `window-latency` scenario on an idle, unlocked console,
  ten samples each, medians and worst case recorded per release. No change until numbers exist.
- **Step 2, pre-build:** after launch and after each editor opens, build one hidden editor window
  with its hosting hierarchy and reuse it for the next capture; warm the shareable-content query
  the same way. One spare at most, released under memory pressure.
- **Proof:** the scenario's medians before and after, on the same machine and build settings.
- **Risk:** a hidden window must not count as a switchable window (`AppPresence`) or join a Space
  early (`SpacePolicy`); both have scenarios that would catch it.

## Class B — what each decision would unlock

- **B-1 Quick-action thumbnail.** The largest change to daily use: most captures end in one
  action, and the references make that action one click or one drag [P]. A possible shape: a
  setting "After a capture: open the editor (default) or show quick actions"; the thumbnail is a
  nonactivating panel that joins all Spaces; every action goes through `ExportPipeline`; the
  capture is held in `ImageStore` and discarded when the thumbnail is dismissed or after a stated
  time. Decisions needed: is a dismissed capture discarded or kept until quit; what the default
  is; whether automatic copy and save run before the thumbnail appears.
- **B-2 Shortcuts actions.** Typed App Intents first (Capture Region, Capture Window, Capture
  Text, Open Image, Pin Image), because they are visible and reviewable in Shortcuts and carry no
  free-form parsing. Rule to adopt before any code: no action exports, uploads or captures without
  the same on-screen step the menu command shows.
- **B-3 Pins on top.** A per-pin "Keep on top" switch, off by default, would keep ADR-007's
  default while offering what both references treat as the point of pinning [P]. Click-through
  needs a visible way back (a menu command that unlocks every pin).
- **B-5 Updater.** The specification exists (`docs/specs/signed-updater/`); only the key-custody
  decision is missing. Until then updates ship by DMG and cask.
- **B-6 Restore last closed.** One slot, in memory, cleared on quit and after a stated time,
  never written to disk. It is the only form of "history" compatible with the no-archive rule,
  and still needs an explicit yes.

## Suggested order

1. **0.15 — everyday friction (all class A, small):** A-1, A-2, A-3, A-9, A-12, and step 1 of A-13.
   Low risk, each independently shippable, and A-13's numbers are needed by everything after.
2. **0.16 — precise capture:** A-4, then A-5 behind its setting, and step 2 of A-13.
3. **0.17 — redact and present:** A-6, A-7, A-8, then A-10 and A-11.
4. **In parallel, decisions:** B-1 first, since it reshapes the capture flow and would change how
   A-5 is built; then B-3 and B-2.

Every item ships with a failing test first, in English and pt-BR, and a dark rendering under the
`ChromeAppearance` check added in 0.14.

## Decisions for the owner

1. Approve class A as planned work for 0.15 (then it becomes backlog tasks from FP-047 on)?
2. B-1: do you want the quick-action thumbnail, and should it replace opening the editor by default?
3. B-3: may pins offer "Keep on top", amending ADR-007?
4. B-5: who holds the updater's signing key?
5. B-2: approve FR-16 automation, starting with Shortcuts actions under the "no silent capture or
   export" rule?
