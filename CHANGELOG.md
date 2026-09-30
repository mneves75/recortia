# Changelog

All notable changes to Recortia are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.9.1-beta1] - 2026-09-29

### Security

- Ordinary document edits invalidate completed OCR and QR results; stale text and links can no
  longer be copied or opened. Closing an editor releases these results.
- Privacy changes immediately discard the old base preview, including duplicated source layers,
  even when the replacement render fails.
- Capture dimensions are bounded before ScreenCaptureKit allocates still or scrolling surfaces.
- Automatic scrolling checks target ownership, unchanged bounds, and the window under the event
  point before posting each event. Synthetic E2E no longer registers a global Escape key.
- Saving first attempts exclusive creation; a collision requires explicit replacement consent.

### Fixed

- Deleted image assets are released after their last undo-history reference is evicted; remaining
  duplicate layers continue to retain their shared source.
- Escape cancels move, resize, and numbered-step gestures without retaining a partial edit.
- Crop bounds round outward to preserve every selected source pixel.
- A suspended automatic-scroll step no longer blocks a replacement session.
- Clipboard failure messages no longer promise preservation that AppKit cannot guarantee.
- Toolchain detection drains Swift's output without an intermittent SIGPIPE gate failure. The
  repository gate includes toolchain and E2E-isolation regression controls.
- Localization validation scans the selected build configuration and rejects missing artifacts;
  stale Release strings no longer contaminate Debug verification.

- Scrolling capture now binds the window under the selected region and stops when that window,
  an unrelated foreground app, or the display changes, including while paused or when a frame was
  already buffered. Automatic scrolling refuses to start when a third app has focus.
- Changing or restoring shortcuts unregisters the old assignments before writing new ones, so a
  shortcut still owned by macOS is never briefly registered by Recortia. The recorder refreshes
  its displayed combination even when the status stays active.
- The release manifest records the same source commit used for its clean checkout, even if the
  working branch advances during the build.
- The exported app includes Recortia's MIT license and the pinned KeyboardShortcuts MIT notice;
  the release pipeline verifies both notices against their sources.
- The shortcut E2E scenario uses its isolated fake system-shortcut state rather than the host's
  real shortcut settings. Compiler warnings in drag-out, export tests, and app conformance were
  also removed.

## [0.9.0-beta5] - 2026-09-27

### Added

- Default shortcuts that match the macOS Screenshot app: ⇧⌘3 captures the display, ⇧⌘4 a region,
  and ⇧⌘5 shows every capture mode in a menu at the pointer (Show Capture Menu). While selecting a
  region, Space switches to choosing a window, as in macOS.
- Recortia never changes the macOS shortcuts. While macOS still uses one of these keys, Recortia
  holds its own shortcut instead of registering it, marks it in Settings and onboarding, and opens
  System Settings › Keyboard for you; it starts using the keys about two seconds after the macOS
  shortcut is turned off. If a macOS shortcut is turned back on, a press is left to macOS, and if
  macOS cannot list its shortcuts, Recortia holds its own.
- Restore Defaults in Settings › Shortcuts.

### Changed

- New installs get these defaults; upgrading keeps your current shortcuts (you may have given these
  keys to another app), and Restore Defaults applies them. A default you clear stays cleared.
- Another app's ordinary shortcut on the same keys cannot be detected; onboarding asks you to clear
  a default another screenshot app already uses.
- SPEC FR-01 and ADR-005 record the decision (it replaces "no default shortcuts").

## [0.9.0-beta4] - 2026-09-26

### Security

From a second, scoped security audit (run-2), a two-axis code review, and an independent Codex
review of the whole branch:

- A layer added or moved under an existing redaction is now masked in its source pixels before it
  is scaled, so the edge around the black box can no longer carry blurred hints of what it hides.
- A drag-out whose file the receiving app already wrote is reported as done, never canceled or
  stale; any other ending of the offer (closing the chip, a delivery elsewhere) revokes it, so a
  late request from another receiver gets nothing. Writing no longer blocks the interface.
- If the preferences seal cannot advance, its secret is removed, so an older sealed settings file
  can never turn automatic export back on.
- JPEG imports are checked through every frame and scan header (at most 128 scans), not only up
  to the first scan.
- Capture keeps excluding Recortia as an application even when it has no window on screen.
- QR links show the host they open in full, next to Open Link.
- From an independent Codex review of the whole branch: a secure mask drawn over a magnifier now
  hides it (masks are the topmost layer in the export and the editor); moving a layer under a mask
  clears recognized text, QR results, and pins made before; automatic copy and save check the
  live editor, so an edit or redaction made while they render stops them; capture fails instead of
  running when Recortia cannot be excluded as an application.

### Fixed

- Automatic scrolling that stops because the page stopped moving is labeled partial unless the
  page reports it reached its end (lazy-loading pages are no longer called complete).
- Settings says when automatic copy, save, or scrolling was turned off because their saved settings
  could not be verified.
- Pausing a scrolling capture while a frame was being stitched no longer stops collection for good;
  stationary frames in automatic mode are also labeled partial unless the page confirms its end.
- Scrolling capture stitches content that scrolls in a narrow column between static margins, and
  its matching memory is bounded (768 KiB of scratch) regardless of frame size.
- Undo memory counts replaced strokes and text, and an undone image whose redo step is gone is
  released instead of kept until the editor closes.
- QR codes in Kanji mode or another ECI character set are no longer dropped.
- Escape cancels a delayed capture while its countdown shows, although the countdown never takes
  focus from the app being captured.
- Pin opacity now reveals what is behind the pin.
- The localization gate also checks plural and device variants.

### Changed

- `scripts/release.sh` builds only a tagged commit, from a fresh checkout with its own build and
  package caches, runs the full gate first, checks the built version, and records the dependency
  inventory; `--dry-run` builds locally without the tag, gate, or notarization.
- CI installs a pinned, checksum-verified XcodeGen.
- ADR-004 records the drag-out lease semantics.

## [0.9.0-beta3] - 2026-09-26

### Security

Fixes from an independent Codex (gpt-6-astra) review of the hardening:

- The preferences seal secret moved to the data-protection keychain under Recortia's keychain
  access group (Developer ID provisioning profile), so another process can no longer delete and
  replace it; each save advances a generation, so an older sealed preferences file restored by
  another process no longer re-enables automatic copy or save. Automatic export settings from
  earlier betas must be turned on again once.
- A drag-out counts as delivered only once the receiving app has written the file; until then
  a new redaction, Cancel, or closing the editor still revokes it, and a revoke never interleaves
  with the write.
- Capture keeps excluding Recortia as an application even when one of its panels closes while
  the capture starts.
- A canceled scrolling capture whose stream finishes starting late no longer stops the next
  session's stream.

## [0.9.0-beta2] - 2026-09-26

### Fixed

- The drag-out chip's title, hint, and VoiceOver label are now in Brazilian Portuguese; the gate
  fails when any extracted string lacks a pt-BR translation.
- The delayed-capture countdown no longer truncates its text.

### Changed

- The end-to-end runner and its synthetic fixtures build only in a separate `RecortiaE2E` target,
  so the shipped app contains neither.
- CI skips Vision OCR recognition tests on hosted runners that cannot run them, with a control
  test that fails if Vision starts working there; the local gate still runs them.

## [0.9.0-beta1] - 2026-09-26

First public beta. The v1 scope (SPEC.md FR-01…FR-14) is implemented; hardware and manual
validation is still in progress.

### Added

- Menu-bar app with onboarding, native Settings (General, Shortcuts, Capture, Export, Privacy, OCR,
  Pins, Scrolling), and user-assigned global shortcuts with registration-failure reporting.
- Region, display, window (with a chooser), delayed, and repeat-last-region capture through
  ScreenCaptureKit, with Recortia's windows excluded and regions kept on one display.
- Bounded PNG/JPEG import from file, paste, and drop (64 MiB and 40 MP limits, single frame,
  orientation applied once, structural PNG validation).
- Editor with text, arrow, rectangle, ellipse, freehand, highlighter, and numbered steps; selection,
  move, resize, duplicate, z-order, keyboard nudging, crop, resize, zoom, and pan; grouped undo with
  a visible notice when old steps are evicted.
- Secure solid redaction bound to source pixels, applied before any resampling or effect; blur and
  pixelate labeled cosmetic.
- Export through one sanitizing pipeline: fresh PNG/JPEG encoding with a metadata allowlist,
  single-PNG clipboard, atomic saves, and a drag-out chip.
- On-device OCR (English, Portuguese) with raw, normalized, and line-preserving text; QR decoding
  that treats payloads as untrusted and opens only http/https links on click.
- Up to five floating pins, closed automatically when their source's redactions change.
- Manual scrolling capture with consensus matching that pauses on ambiguity, limits, and labeled
  partial results; opt-in automatic scrolling that stops on any focus or target change.
- Nearest-neighbor loupe, ruler, and sRGB color picker.
- Multi-image composition, side-by-side preset, transparency comparison, background, padding,
  rounded corners, shadow, spotlight, and magnifier callouts.
- English and Brazilian Portuguese localization.

### Security

Fixes from the pre-release security audit (source review of `f26b6d2`, three hunting waves):

- A pending drag-out is revoked when the document changes, the export is canceled, or the editor
  closes, so a snapshot older than a new redaction is never written by the receiving app.
- Secure masks are applied before blur and pixelate, so a layer added under an existing mask cannot
  leak through a nearby cosmetic effect.
- Automatic copy, automatic save, the save folder, and automatic scrolling are honored only from
  preferences Recortia sealed itself (HMAC keyed by a login-keychain secret); another process that
  rewrites the preferences domain cannot turn them on. Save-folder bookmarks resolve without
  mounting volumes. The key is created at first launch; a process that plants it before then is a
  documented residual until the data-protection keychain is adopted.
- Screenshots and scrolling capture exclude Recortia as an application, so pins and the drag chip
  created mid-capture never appear in frames; a scroll session canceled before it started no longer
  leaves a capture stream running.
- Imports open non-blocking without following a final symlink; Apple's `iDOT` chunk is withheld
  from ImageIO so it decodes only the validated `IDAT` stream; PNGs with excessive `IDAT` chunks and
  JPEGs with two frame headers are rejected.
- QR payloads whose bytes disagree with Vision's string are dropped; web links carrying a user or
  password are refused; a QR link opens only if it is still the payload that was displayed.
- CI resolves packages only from `Package.resolved` and fails when XcodeGen is missing.

### Known limitations

- Not yet validated on macOS 15/26, 1× or mixed-DPI multi-display setups, or against the real-app
  scrolling compatibility matrix.
- Automatic scrolling scrolls downward only.
- No in-app updater yet; update with Homebrew or a new DMG.
