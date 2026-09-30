# Recortia

A native, local-first macOS screenshot utility: capture, annotate, redact for real, and share —
from the menu bar, without accounts, uploads, or a screenshot archive.

**Status:** beta source candidate (0.9.1-beta2, build 8). The v1 features FR-01…FR-13 in `SPEC.md` are built, and FR-14 except its
in-app update flow (updates come through Homebrew or a new download); they are covered by automated
and end-to-end tests, but not every acceptance case has passed yet: hardware capture,
multi-display geometry, the scrolling compatibility matrix, VoiceOver passes, performance budgets,
and the in-app updater are pending (see [Validation status](#validation-status)). Betas are published
as regular GitHub releases so that Homebrew and the Releases "latest" link follow them; the version
number says beta. Recortia is an independent project and is not affiliated
with Shottr or any other screenshot tool.

## Install

Requires macOS 15 or later on Apple Silicon.

```sh
brew install --cask mneves75/tap/recortia
```

Or download the notarized DMG from [Releases](https://github.com/mneves75/recortia/releases).

The current source candidate has not been published as a DMG. A local Developer ID-signed
0.9.1 build 7 was installed on the maintainer's Mac on 2026-09-29; it has not been notarized.
The beta2 documentation/build-number follow-up does not replace that installed build.

## What it does

- **Capture** a region, a display, or a chosen window; delayed capture; repeat the last region.
  Recortia's own windows are excluded; regions stay on one display.
- **The macOS shortcuts**: ⇧⌘3 captures the display, ⇧⌘4 a region (press Space for a window), and
  ⇧⌘5 shows every capture mode at the pointer. They start working once you turn the macOS ones off
  in System Settings › Keyboard › Keyboard Shortcuts › Screenshots; Recortia never changes them
  itself and says which ones macOS still uses ([ADR-005](docs/adr/0005-macos-default-shortcuts.md)).
- **Annotate** with text, arrows, rectangles, ellipses, freehand, highlighter, and numbered steps;
  select, move, resize, duplicate, reorder, crop, resize, zoom, and pan with grouped undo.
- **Redact securely.** The solid redaction tool replaces source pixels before any resampling or
  effect, so the exported image cannot depend on what was underneath. Blur and pixelate are
  available and clearly labeled cosmetic, never secure.
- **Export deliberately.** Copy (a single sanitized PNG), Save (atomic, PNG or JPEG), or drag out.
  Exports are freshly encoded with an allowlist of metadata: no EXIF, GPS, text chunks, or
  hidden layers.
- **Read text and QR codes on device** with Vision (English and Portuguese). QR payloads are shown as
  untrusted data; only http/https links open, and only when you click.
- **Pin** up to five floating references with adjustable opacity and zoom.
- **Scrolling capture**, manual by default; automatic scrolling is opt-in and asks for Accessibility
  only when you turn it on. Ambiguous matches pause instead of producing a wrong stitch. A live
  session stops if its source window, an unrelated foreground app, or its display changes.
- **Pixel tools**: nearest-neighbor loupe, ruler, and sRGB color picker (HEX/RGB).
- **Compose and present**: multiple images on one canvas, side-by-side, background, padding,
  rounded corners, shadow, spotlight, and magnifier callouts.
- English and Brazilian Portuguese; keyboard-accessible, with VoiceOver labels.

## Privacy

- Everything runs on your Mac. Recortia makes no network requests.
- Nothing is written to disk or the clipboard until you choose Copy, Save, or drag out
  (auto-copy and auto-save exist and are off by default).
- Screen Recording is requested at your first capture, not at launch. Opening and editing images
  never needs it. Accessibility is requested only for automatic scrolling.
- Public DMGs are distributed outside the App Store, signed with Developer ID and notarized, without
  App Sandbox, because the sandbox forbids the Accessibility APIs automatic scrolling needs
  ([ADR-002](docs/adr/0002-permission-and-sandbox-profile.md)).

Redaction protects the exported image. It cannot recall copies you exported earlier or other
apps' clipboard histories.

## Build from source

Stable Xcode 27.0 (see `TOOLCHAIN.json`) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
If `xcode-select` points to a beta, prefix commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```sh
scripts/check.sh --unsigned    # toolchain doctor, format lint, project freshness, tests, app build
scripts/e2e.sh --lang all      # end-to-end scenarios through the real app; writes screenshots + report
scripts/release.sh             # maintainer only: Developer ID archive, checks, DMG, notarize, staple, manifest
```

Run one test: `swift test --package-path Packages/RecortiaKit --filter <TestName>`.

`project.yml` owns the base version and build number; regenerate the Xcode project with
`xcodegen generate` after changing them. Beta candidate names also appear in this status,
`CHANGELOG.md`, and `BACKLOG.json`. A source version bump does not update an installed app.

For a local Developer ID installation, use the archive/export steps in `scripts/release.sh`
with the existing signing identity and provisioning profile, after owner authorization.
Follow the artifact checks in `AGENTS.md`; a successful Release `build` action alone does
not prove that the app has distribution entitlements. Local installation does not run
notarization or publish a release.

Layout: `RecortiaApp/` (AppKit + SwiftUI app), `Packages/RecortiaKit` with `Domain` (document model,
geometry, state machines), `Imaging` (decode, privacy renderer, export, OCR, QR, stitching),
`MacPlatform` (ScreenCaptureKit, permissions, sinks), `Features` (feature models), and
`RecortiaFixtures` (synthetic test inputs).

## Validation status

Automated: Swift Testing suites for every module, including the redaction metamorphic tests
(RED-01…RED-04) with planted-leak controls, import hardening (IO-01), export container inspection,
OCR accuracy on a 104-sample EN/PT-BR corpus, and scroll stitching with held-out calibration, plus
the end-to-end scenario runner (20 scenarios in English and Brazilian Portuguese).

Security: source reviews and synthetic regressions cover redaction, export boundaries, input
limits, asynchronous freshness, and cancellation. The 0.9.1-beta1 corrections are listed in
`CHANGELOG.md`; accepted residuals and the limits of live verification remain in `THREAT_MODEL.md`.
These checks do not establish that all platform behavior or security risks have been eliminated.

Release evidence: PR #3 and its post-merge unsigned CI passed for the beta1 source. The local
0.9.1 build 7 archive/export succeeded with stable Xcode 27.0; strict signature verification,
Hardened Runtime, the embedded provisioning profile, the protected Keychain access group,
absence of the debug entitlement, and byte equality between the export and installed bundle
were checked. The existing running session was preserved; launch after replacement and
clean-user/offline behavior were not verified. This is partial REL-02 evidence, not a
notarized distribution or production qualification. `BACKLOG.json` records the source,
artifact hash, CI links, and local evidence paths.

Not yet validated: live capture on 1× and mixed-DPI multi-display setups (GEO-01), macOS 15 and
26 hosts, the real-app scrolling compatibility matrix (SCR-03), VoiceOver and input-method passes
on hardware, and performance budgets on a stable-OS Mac (PERF-01). The in-app updater is not
built yet; update with `brew upgrade --cask recortia`.

## Documents

`SPEC.md` (product contract) · `AGENTS.md` (engineering boundaries) · `IMPLEMENTATION_PLAN.md` and
`BACKLOG.json` (tasks) · `ACCEPTANCE_TESTS.md` · `THREAT_MODEL.md` · `docs/adr/` (decisions) ·
`CHANGELOG.md` · `CONTRIBUTING.md` · `SECURITY.md`. The original documentation-only handoff is
preserved in `docs/handoff/`.

## License

[MIT](LICENSE). The app bundle includes this license and the pinned KeyboardShortcuts MIT notice.
