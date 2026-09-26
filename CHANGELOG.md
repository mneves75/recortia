# Changelog

All notable changes to Recortia are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

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

### Known limitations

- Not yet validated on macOS 15/26, 1× or mixed-DPI multi-display setups, or against the real-app
  scrolling compatibility matrix.
- Automatic scrolling scrolls downward only.
- No in-app updater yet; update with Homebrew or a new DMG.
