# Changelog

All notable changes to Recortia are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

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

### Fixed

- Automatic scrolling that stops because the page stopped moving is labeled partial unless the
  page reports it reached its end (lazy-loading pages are no longer called complete).
- Settings says when automatic copy, save, or scrolling was turned off because their saved settings
  could not be verified.

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
