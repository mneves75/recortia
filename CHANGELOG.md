# Changelog

All notable changes to Recortia are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

Each section covers one published release. Candidates that were never tagged (0.9.1, 0.10.0,
0.12.0 and 0.12.1) are folded into the release that first shipped their changes, and the
0.9.0 betas into one section. Build, gate and installation evidence for every candidate is in
`BACKLOG.json`.

On 2026-10-16 the repository history was squashed into one commit and the releases before
0.12.2-beta1 were withdrawn from GitHub; their sections remain as a record of what changed.

## [Unreleased]

## [0.12.3] - 2026-10-18

Build 22. Fixes the four open items from the 0.12.2 security review. Physical keyboard, Spaces
and permission checks of this build were not run.

### Fixed

- Automatic copy and save check their setting again just before writing: turning either off, or
  changing the save folder, while a capture is still being prepared now stops that write.
- Replacing an existing file keeps its permissions, so a file readable only by you stays that
  way; the new content is also written owner-only until it replaces the old file.
- The release check that keeps test-only code out of published builds now also scans universal
  binaries with 64-bit offsets.
- The end-to-end runner refuses to record its evidence when the source changed during the build.

## [0.12.2-beta1] - 2026-10-16

Build 21, on Homebrew and GitHub. First published as a pre-release; re-published on 2026-10-16
on the squashed history with the same notarized disk image. Physical keyboard, Spaces and
permission checks of this build were not run.

### Added

- Curved arrows: drag the bend handle or type Bend X/Y, and switch an arrow between Curved and
  Straight. Exports keep connected heads and stroke opacity.
- A straight-line tool (shortcut D) with editable endpoints and no arrowheads.
- Seven text appearances: standard, rounded, monospaced, outlined, boxed, rounded box and
  monospaced box. Boxed text has a background color with Reset to automatic white, and native
  text input shows the appearance while you type.
- Saved annotation colors: one palette of up to 12 colors shared by every editor, with Save,
  Apply and Remove.
- The color picker samples 1×1, 3×3 or 5×5 pixels; area samples average the sanitized preview.
- A skippable seven-page first-run tour in English and Portuguese. **Feature Tour** in the
  menu-bar menu replays it without resetting preferences, shortcuts or first-run completion.

### Changed

- Every editor window opens at one size: the last size you resized an editor to, or 1100×720,
  kept within the screen. Before, each capture's size set the window size.
- Onboarding explains that automatic exports happen before redaction and later edits, which
  cannot recall copies already made.
- The automated tests keep only checks that fail when a break matters to a user, to data or to
  security: 779 test functions became 553
  ([record](docs/specs/test-reduction/README.md)).

### Fixed

- An image import or keyboard nudge that lands during a drag is kept; the drag settles first
  and each becomes its own Undo step.
- Committing text, importing an image, applying a saved color and editor commands (nudge,
  delete, duplicate, arrange, crop, renumber, composition) close a pending color adjustment
  first, so Undo restores each step separately.
- Automatic scrolling sends scroll events only to the window bound at capture start, even when a
  floating window covers it. Stop during startup halts capture, and Resume after Stop no longer
  scrolls while the final frame settles.
- Secure masks refuse layers whose geometry cannot be mapped instead of skipping them.
  Scrolling capture counts the matcher's working memory against its limit.
- Closing an editor cancels its own export, upload or automatic batch, so other editors are no
  longer told the exporter is busy.
- Wrapped text paints every line after resizing and zooming; the zoomed canvas and its text
  fields stay inside the viewport.
- A text layout failure clears the partial canvas and reports an error; exports fail with the
  same error instead of producing a partial image.
- Rounded and monospaced fonts are retried when macOS briefly returns no font. This mitigates
  the failure; its cause is not established.
- `scripts/release.sh` refuses an existing output directory instead of deleting a retained
  archive. `scripts/e2e.sh` records build provenance, and `--no-build` refuses a binary that does
  not match it. The project freshness check fails when XcodeGen is missing.

## [0.11.0] - 2026-10-08

Build 18. The physical window-switcher, ⌘Tab and fullscreen-Space checks of this
build were not run.

### Added

- Pins can be copied (⌘C) and dragged out. Both export the pinned image as the editor's 1×
  export would, without metadata. Closing a pin, or a redaction that removes it, cancels an
  undelivered drag. Adopted from [Tendedero](https://github.com/alejandrobujan/tendedero)'s
  click-to-copy and drag-to-share.
- Recortia appears in ⌘Tab and the Dock while one of its windows is open, including a minimized
  one. Clicking the Dock icon restores a minimized window. The app menu has Settings… (⌘,).

### Changed

- Pins are ordinary windows, so window switchers such as AltTab (⌥Tab) list them. They no longer
  float above other windows; ⌥Tab, ⌘Tab or Bring Pins Forward brings them back.

### Fixed

- Opening Recortia from Finder, Spotlight or the Dock shows Settings (onboarding on the first
  run) instead of only adding its menu-bar icon. "Open at login" still starts silently once
  onboarding is complete.

### Known limitations

- On the build Mac, first opening the editor took 229–640 ms and Settings 105–248 ms, over the
  50 ms budget (PERF-02).

## [0.10.2] - 2026-10-03

Build 16; the same source shipped first as 0.10.2-beta1.

### Fixed

- Settings opens on the Space you are using, including another app's fullscreen Space. 0.10.1
  said this was fixed, but its Settings window could still switch you to a desktop Space.
  Settings is now Recortia's own window with the same tabs.

## [0.10.1] - 2026-10-03

Build 14; the same source shipped first as 0.10.1-beta1. Includes the untagged 0.9.1 and 0.10.0
candidates.

### Added

- Optional automatic upload of still captures to a private GitHub repository you configure, with
  a separate opt-in, a token kept in the Keychain, sanitized exports, an 8 MiB limit, redirect
  refusal and honest reporting when completion is uncertain.

### Changed

- Every window Recortia shows follows the Space you are on, including another app's fullscreen
  Space; capture panels, HUDs and pins appear on every Space. The editor can no longer enter its
  own fullscreen Space.
- The editor and the scrolling review open on the display you captured; HUDs, the drag chip and
  new pins open on the display under the pointer.
- Release builds notarize and staple the app before building the disk image, and scan every
  binary for test-only code.

### Fixed

- Starting a capture hides Recortia's open windows during selection and restores them
  afterwards without closing documents or taking focus. Still and scrolling captures cannot
  overlap.
- Region capture from a shortcut no longer activates Recortia or brings another desktop forward.
- Quitting asks before discarding edits that were never exported.
- A display that changes between selection and capture stops the capture with a clear message.
- Canceling automatic copy cancels the rest of the batch, including save and upload. Skipped or
  failed automatic exports are reported in the editor instead of an alert, and editor notices
  are announced to VoiceOver.
- Dismissing the capture menu (⇧⌘5) returns keyboard focus to the app you were using.
- A large pin is sized for the display it opens on.
- Imports share one read slot across documents and layers; overlapping requests are refused
  before any bytes are read. Dropping an image works after the drag pasteboard is cleared.
- Holding Space no longer leaves the canvas stuck in pan mode after focus changes.
- Changing the GitHub destination removes the previous token, and revoking or resetting upload
  permanently invalidates pending upload consent.
- A renamed or moved save folder keeps working.
- Scrolling capture checks its memory budget before each frame, no longer counts frames whose
  colors change as a stopped page, and stops when its window, the foreground app or the display
  changes; automatic scrolling refuses to start when a third app
  has focus.
- An empty or off-canvas crop is refused instead of exporting the whole canvas; crop bounds keep
  every selected pixel.
- Escape cancels move, resize and numbered-step gestures; the countdown accepts a click.
- Shortcuts held by macOS are rechecked with backoff, and changing shortcuts never briefly
  registers one macOS still owns.
- Editing an image's height resizes it proportionally.

### Security

- Ordinary edits invalidate recognized text and QR results, so stale text and links cannot be
  copied or opened.
- Privacy changes discard the old preview immediately, even when the new render fails.
- Capture dimensions are bounded before ScreenCaptureKit allocates surfaces.
- Automatic scrolling checks the target window and the window under the pointer before each
  event. Stopping screen sharing through macOS cancels the scrolling session and discards the
  stitch.
- Saving never replaces an existing file without explicit consent.
- Pixel tools reject coordinates outside the integer range and clamp extreme loupe radii instead
  of crashing.
- Release checks parse the actual Keychain access-group entitlement and reject debug
  entitlements.
- The app bundle includes Recortia's MIT license and the KeyboardShortcuts notice, verified by the
  release pipeline.

## [0.9.0-beta5] - 2026-09-27

The first public betas, 0.9.0-beta1 (2026-09-26) through 0.9.0-beta5 (2026-09-27). The v1 scope
(SPEC.md FR-01…FR-14) is implemented; hardware and manual validation was still in progress.

### Added

- Menu-bar app with onboarding, native Settings and global shortcuts. The defaults match the
  macOS Screenshot app: ⇧⌘3 display, ⇧⌘4 region (Space picks a window) and ⇧⌘5 the capture menu.
  Recortia never changes the macOS shortcuts; while macOS holds one, Recortia holds its own and
  says how to free it. Upgrading keeps your current shortcuts; Restore Defaults in Settings ›
  Shortcuts applies the defaults, and a default you clear stays cleared.
- Region, display, window, delayed and repeat-last-region capture through ScreenCaptureKit, with
  Recortia excluded and regions kept on one display.
- Bounded PNG/JPEG import from file, paste and drop (64 MiB and 40 MP limits).
- Editor with text, arrows, rectangles, ellipses, freehand, highlighter and numbered steps;
  selection, move, resize, duplicate, z-order, nudging, crop, resize, zoom, pan and grouped undo.
- Secure solid redaction applied to source pixels before any resampling or effect; blur and
  pixelate labeled cosmetic.
- One sanitizing export pipeline: fresh PNG/JPEG encoding with a metadata allowlist, single-PNG
  clipboard, atomic saves and a drag-out chip.
- On-device OCR (English, Portuguese) and QR decoding that treats payloads as untrusted and opens
  only http/https links on click.
- Up to five pins, closed when their source's redactions change.
- Manual scrolling capture that pauses on ambiguity, and opt-in automatic scrolling that stops on
  any focus or target change.
- Loupe, ruler and sRGB color picker; multi-image composition, background, padding, corners,
  shadow, spotlight and magnifier callouts.
- English and Brazilian Portuguese.

### Fixed

- Automatic scrolling that stops because the page stopped moving is labeled partial unless the
  page reports its end; pausing during a stitch no longer stops collection for good.
- Scrolling capture stitches content between static margins with bounded matching memory.
- Undo memory counts replaced strokes and text, and releases unreachable images.
- QR codes in Kanji mode or another ECI character set are decoded.
- Escape cancels a delayed capture; pin opacity reveals what is behind the pin.
- Settings says when automatic copy, save or scrolling was turned off because their saved
  settings could not be verified.
- The drag-out chip is translated, and the localization gate fails on any untranslated string.

### Security

- Secure masks apply before blur, pixelate and scaling, and a mask over a magnifier hides it, so
  nothing near a mask can carry hints of what it hides.
- A drag-out counts as delivered only after the receiving app writes the file; any change,
  cancellation or close before then revokes it.
- Automatic copy, save, the save folder and automatic scrolling are honored only from
  preferences Recortia sealed itself, with the seal key in the data-protection keychain.
  Automatic export settings from beta1 and beta2 must be turned on again once.
- Capture excludes Recortia as an application and fails instead of running when it cannot.
- Imports refuse symlinks, malformed PNG chunks, multiple JPEG frames and excessive scans.
- QR links show their full host; links carrying credentials are refused.
- The end-to-end runner builds only in a separate target, so the shipped app contains neither it
  nor its fixtures. CI resolves packages only from `Package.resolved`.

### Known limitations

- Automatic scrolling scrolls downward only.
- No in-app updater; update with Homebrew or a new DMG.
