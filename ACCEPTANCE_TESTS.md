# Acceptance tests and release gates

**Status:** Acceptance contracts with partial automated verification. Package regressions and
synthetic native E2E have executed; live hardware, permissions, accessibility, performance, and
notarized distribution qualification remain pending. A signed local archive/export and installation
were verified for 0.9.1 build 7; clean-user launch and TCC checks were not. See README.md and
BACKLOG.json for current evidence.

Every automated test must produce machine-readable results. Image fixtures must declare their generator/source, license, scale, color space, dimensions, and expected output. Use fixed seeds for generated noise/geometry. Use golden outputs only where their provenance and expected meaning are documented; never bless a broken output just to make CI green.

## Capture, permissions, and geometry

### PERM-01 — Just-in-time permission and denial

Given a clean test user without Screen Recording or Accessibility grants, launching the app and opening a local image does not ask for screen access. Requesting screen capture shows the appropriate explanation and OS flow. Denial leaves menus/settings/import/edit/export functional. Accessibility is not requested for an ordinary screenshot. Mock-provider tests are supplemented by a real signed-app run.

### PERM-02 — Revocation and cancellation cleanup

While selecting, capturing, recognizing text, and collecting scroll frames, inject each of cancellation, target closure, display removal, screen lock, and permission loss. The app removes overlays, ends streams, releases frame handlers, ignores late completions, and produces no new clipboard or file write. Test canceled-operation completions arriving both before and after a replacement request.

### CAP-01 — Modes and source correctness

On each supported OS, capture a region, each display, a chosen window, a delayed target, and a repeated region. Compare a synthetic fixture's numbered corners and boundaries against expected output. Window ambiguity produces a chooser. Cursor/shadow toggles change only the declared content. The app's checkerboard overlays and reference pins are absent by default.

### CAP-02 — One active capture and no idle recording

Rapidly invoke capture 20 times. Assert the declared replacement/cancellation policy, maximum one active session, and no queued background captures. After completion/cancel, instrument zero active SCStreams and no new screenshot buffers while idle. A second process invocation reuses the existing application.

### GEO-01 — Mixed-DPI desktop matrix

Use displays at 1x and 2x, a display to the left/above the primary, different resolutions, and a rotated display where hardware allows. Test all four selection directions, one-pixel edges, fractional logical coordinates, and display unplug/replug. Exported pixel bounds agree with the geometry contract; there are no inverted crops, seams, or silent cross-display resampling.

### GEO-02 — Property tests for transforms

For generated valid transforms, round trips agree within the documented subpixel tolerance before raster rounding. Crop and mask bounds always cover the intended source pixels after outward rounding and clipping. NaN, infinity, overflow, zero/negative sizes, singular transforms, and coordinates outside the image fail safely. Imported images have no invented screen-point scale.

## Editor, import, and pins

### IO-01 — Defensive import

Test valid PNG/JPEG; truncated headers; corrupt payloads; oversized declared dimensions; decompression bombs; unsupported animation; unexpected orientation; malicious metadata; a 64 MiB boundary; and a 40 MP boundary. Reject unsafe inputs without unbounded allocation, network access, source mutation, or app crash. Clipboard input occurs only after Paste.

### EDIT-01 — Deterministic editor replay

Replay a fixed script creating each annotation, editing text, dragging/resizing/duplicating, changing z-order, cropping, and resizing the document. Undo every operation, redo it, and verify model equality and expected render. A complete pointer gesture is one undo group. Exercise the undo-budget boundary without breaking remaining commands.

### EDIT-02 — Zoom, focus, and text composition

At 25%, 100%, 200%, and 800% zoom, the same document-space operation produces the same image geometry. Test keyboard nudging, panning, and hit targets. Accented Portuguese, emoji, right-to-left text, multiline editing, and an input method do not lose characters or accidentally trigger tool shortcuts. Text layout regressions use per-OS baselines where system typography differs.

### PIN-01 — Reference lifecycle

Create five pins, reach the budget limit, move between displays/Spaces, vary opacity, close the editor, and close each pin. No invisible window blocks user input. Closing pins releases their retained snapshots. A source-document privacy-epoch change updates or invalidates linked pins and prevents a stale raw view from being re-exported.

## Redaction and export — release blocking

### RED-01 — Source-independence metamorphic test

Generate two same-sized source images identical outside a secret region but radically different inside it: text in one, random pixels in the other. Apply the same fully covering solid mask and the same edit recipe. Compare decoded exported pixel buffers; they must be identical, including transformed edges and every derived view that references that asset. Compare metadata against the same allowlist.

Repeat for PNG, JPEG after decoding, clipboard PNG, and drag-out files; later apply it to upload payloads. Repeat through crop, 0.5x/1x/2x resize, blur adjacency, rotated/scaled image layers, alpha handling, a magnifier, and duplicate references to the same asset. This tests dependence on hidden source pixels; failure to recognize text with OCR alone is not a sufficient test.

### RED-02 — No hidden original representations

Inspect PNG chunks, JPEG metadata, all advertised pasteboard types, file promises, exported bytes, thumbnails, and diagnostic attachments. Assert no original layers, OCR strings, source filename, location, custom document payload, original TIFF/file URL, or unredacted preview. Decode fully transparent pixels and check that forbidden source RGB data was not preserved. Essential sRGB interpretation remains valid.

### RED-03 — Mask edges and dependent caches

Mask text touching each image edge and pixels under fractional transforms; then zoom, resize, undo/redo, change the mask, and re-run OCR/magnifier/pin/export. Outdated revisions and privacy epochs cannot reintroduce data. Source-bound redaction propagates to all uses of the same asset. Unsupported transform mappings produce an error/explicit safe flatten path, never an insecure fallback.

### RED-04 — Honest redaction boundary

The UI distinguishes solid redaction from cosmetic obfuscation, and does not call blur/pixelation secure. Independently imported duplicate secrets and earlier exports are explicitly outside automatic propagation. A canceled redaction/export operation does not silently copy the original. User-visible help does not claim complete secret detection or forensic erasure.

### EXP-01 — Single export pipeline and visual fidelity

For each supported format and scale, render the same snapshot through every sink and verify equivalent decoded output under declared encoding differences. Preview/crop/annotation positions match export. PNG alpha and JPEG background are correct. Cosmetic effects cannot bypass masks. The clipboard advertises only the permitted sanitized representation.

### EXP-02 — Commit and failure semantics

Inject render failure, encoding failure, clipboard failure, denied folder access, destination collision, disk full, unplugged volume, and canceled drag. No false success notification. A prior destination file survives a failed atomic save. Clipboard is untouched on failure before write. Successful committed writes are not described as canceled/retracted. Drag receivers get a complete file for the transfer lifetime.

## OCR and pixel tools

### OCR-01 — Local recognition corpus

Build a versioned corpus with at least 100 synthetic screenshots balanced between English and Portuguese, varied system font sizes, light/dark themes, punctuation, digits, accents, multiline text, and code. Report character error rate on a separate clean typed-text subset and on the full corpus. Proposed clean-subset gate: CER <= 1%; do not represent that as universal OCR accuracy. Record actual Vision request revision and language configuration.

Verify bounding-box alignment, raw versus normalized output, supported-language discovery, cancellation, and privacy-epoch invalidation. A no-text result does not clear or replace the clipboard. Disconnected-network tests succeed after any OS-provided language resources required by the environment are already present; report any unavailable system resource rather than silently fetching through a custom service.

### OCR-02 — QR payload safety

Decode fixtures for ordinary text, HTTPS, unsupported schemes, payment/Wi-Fi-like payloads, and malformed codes. Compare expected payload bytes. Nothing opens, connects, executes, pays, or modifies system settings automatically. User cancellation leaves other app state unchanged.

### PIX-01 — Measurements and colors

Use an sRGB chart with known encoded RGB values and exact geometry. HEX/RGB output matches the defined pixel sampling method, ruler distances remain invariant under editor zoom, and point/pixel labels are unambiguous. A nearest-neighbor loupe does not interpolate. Imported images do not acquire a fictitious Retina scale.

## Scrolling and composition

### SCR-01 — Deterministic stitching fixtures

Feed synthetic overlapping viewport sequences of known pages with randomized bounded scroll increments, fixed headers/footers, animated regions, and subpixel-rendering noise. Verify reconstructed content order, exact line sequence, no missing/duplicated rows, and documented seam tolerance. Check stationary frames and end-of-page detection. Do not use broad SSIM as the only metric: it can conceal missing text.

### SCR-02 — Ambiguous and partial results

Provide low-texture pages, identical repeated rows, insufficient overlap, reverse scrolling, lazy-loading reflow, and frame gaps. The matcher either reconstructs correctly or pauses/rejects uncertain frames; it never labels an invalid stitch successful. Manually accepted partial outputs carry a reason and remain editable. Confidence calibration uses held-out fixtures, not only the implementation's development examples.

### SCR-03 — Real application compatibility

Test manual and automatic modes in the declared Safari, Chrome, and native-scroll-view targets on macOS 15/26/27. Record app versions, display configuration, scroll settings, and successful/limited/unsupported outcomes. Include Terminal/virtualized content and a scroll modifier as negative cases. Accessibility denial keeps manual mode available. Target/focus change immediately stops synthetic scrolling.

### SCR-04 — Limits and cancellation

Exercise the 120-second, 200-frame, 40-MP, 32,768-side, 20,000-default-height, and memory-budget limits independently. Accepted-frame buffers remain bounded. Stop remains responsive. Partial results do not cause an encoder allocation beyond the declared budget. No raw temporary image files are created merely to evade a memory limit.

### COMP-01 — Composite rendering and redaction

Combine at least three images with scaling, opacity, overlap, a background, rounded corners, shadows, spotlight, and magnifier. Verify order, aspect ratios, crop, and output size. Reject render-graph cycles. Re-run RED-01 through RED-03 after every new derived effect or export-capable surface.

## UX, privacy, performance, and release

### UX-01 — Keyboard, accessibility, and localization

Verify essential flows using the keyboard; inspect VoiceOver labels and the annotation list; test Reduce Motion/Transparency, increased contrast, focus visibility, and dark/light appearance. Test EN/PT-BR including longer strings and error messages. No control is icon/color-only without an accessible name. The custom canvas exposes deliberate accessibility elements.

### PRIV-01 — Network, persistence, and diagnostics

On a fresh install with update checks off, exercise every v1 core feature while observing app-initiated network traffic. There must be none. Before any explicit save/drag, inspect app-controlled directories for screenshot/OCR persistence; settings-only writes are allowed. Logs contain no test secret strings, QR data, file/window titles, or image content. Explicit diagnostics have an inspectable preview.

### PERF-01 — Performance and lifecycle evidence

Run SPEC.md's stated performance scenarios with the specified sample counts and actual physical hardware. Attach timings/footprint summaries and Instruments traces without sensitive pixels. Separate cold/warm results and human delay. After 200 capture-close cycles, inspect retained object counts and steady-state footprint. If a target fails, record the failure instead of silently redefining the endpoint.

### REL-01 — Independent build and CI boundary

A clean checkout builds with documented, locked inputs and no maintainer account required for unsigned checks. PR workflows contain no release credentials or privileged untrusted checkout. Verify dependency/license inventory and declared toolchain against the produced artifact. Untrusted fork jobs never run on the live-capture test Mac.

### REL-02 — Signed distribution and update safety

With explicit release approval, build from the reviewed tag, sign, notarize, staple, and verify the downloaded artifact on a clean test user. Verify TCC behavior across upgrade and an offline launch. Test valid, corrupted, wrongly signed, interrupted, and OS-incompatible updates; reject unsafe updates while retaining the working app. Document release identity and recovery procedures without exposing keys.

## Gate summary

- **0.1:** PERM, CAP, GEO, IO, EDIT, PIN, RED, EXP, OCR, UX, PRIV, relevant PERF and REL cases pass. No scrolling or pro-tool parity claim.
- **1.0:** All v1 cases pass, with a published scroll compatibility matrix and complete EN/PT-BR/accessibility review.
- **Post-1.0:** NET/AUTO/AI tests must be specified and approved before implementing those features. Existing privacy/export gates continue to apply.

All unexecuted or hardware-dependent cases remain explicitly `unrun`/`awaiting_manual_validation`. A passing unit-test suite does not convert them to passed.
