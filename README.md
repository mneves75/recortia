# Recortia

A native, local-first macOS screenshot utility: capture, annotate, redact for real, read text,
and share from the menu bar. Nothing leaves your Mac unless you turn on the optional GitHub
upload, and Recortia keeps no screenshot archive.

The current version is **0.12.2-beta1** (build 21), signed with Developer ID and notarized,
available through Homebrew and the [latest release](https://github.com/mneves75/recortia/releases/latest).
It is a beta: the physical checks listed under [Known limitations](#known-limitations) have not
run. What changed in each version is in [CHANGELOG.md](CHANGELOG.md).

Recortia is an independent open-source project and is not affiliated with any other screenshot
app.

## Install

Requires macOS 15 or later on Apple Silicon.

```sh
brew install --cask mneves75/tap/recortia
```

Update with `brew upgrade --cask recortia`. Or download the DMG from
[Releases](https://github.com/mneves75/recortia/releases). There is no in-app updater yet.

## What it does

- **Capture** a region, a display, or a chosen window, with a delay or by repeating the last
  region. Recortia's own windows are excluded, a region stays on one display, and existing
  Recortia windows are hidden while you select and restored afterwards.
- **macOS shortcuts.** ⇧⌘3 captures the display, ⇧⌘4 a region (press Space to pick a window),
  and ⇧⌘5 shows every capture mode at the pointer. They take effect once you turn off the macOS
  screenshot shortcuts in System Settings › Keyboard › Keyboard Shortcuts › Screenshots.
  Recortia never changes system settings itself and tells you which shortcuts macOS still holds
  ([ADR-005](docs/adr/0005-macos-default-shortcuts.md)).
- **Annotate** with text, straight or curved arrows, lines, rectangles, ellipses, freehand,
  highlighter and numbered steps. Select, move, resize, duplicate, reorder, crop, zoom and pan,
  with grouped undo.
  - Curved arrows have a bend handle and keyboard-editable coordinates.
  - Seven text appearances: standard, rounded, monospaced, outlined, boxed, rounded box and
    monospaced box, with a background color for boxed text.
  - A saved palette of up to 12 annotation colors is shared by all editors.
- **Redact securely.** Solid redaction replaces source pixels before any resampling or effect,
  so the exported image does not depend on what was underneath. Blur and pixelate are available
  and labeled cosmetic, never secure.
- **Export deliberately.** Copy (one sanitized PNG), save (atomic, PNG or JPEG) or drag out.
  Every export is freshly encoded with an allowlist of metadata: no EXIF, GPS, text chunks or
  hidden layers.
- **Read text and QR codes on device** with Vision, in English and Portuguese. QR payloads are
  shown as untrusted data; only http and https links open, and only when you click.
- **Pin** up to five images with adjustable opacity and zoom, then copy or drag a pin out. Pins
  are ordinary windows, so window switchers list them, and Recortia appears in ⌘Tab and the Dock
  while any of its windows is open.
- **Scrolling capture**, manual by default. Automatic scrolling is opt-in, scrolls downward and
  asks for Accessibility only when you turn it on. Ambiguous matches pause instead of producing a
  wrong stitch, and a session stops if its window, the foreground app or the display changes.
- **Pixel tools**: nearest-neighbor loupe, ruler and sRGB color picker (HEX/RGB), which can
  average a 3×3 or 5×5 area.
- **Compose and present** several images on one canvas: side by side, background, padding,
  rounded corners, shadow, spotlight and magnifier callouts.
- **Works on every desktop**: windows open on the Space you are using, including another app's
  fullscreen Space, and on the display you captured.
- A skippable first-run tour, which you can replay from **Feature Tour** in the menu-bar menu.
  Every editor window opens at one size: the last size you chose, or a default that fits the
  screen.
- English and Brazilian Portuguese; keyboard accessible, with VoiceOver labels.

## Privacy

- Capture, editing and recognition run on your Mac. Recortia makes network requests only after
  you set up and enable the optional GitHub upload, which is off by default.
- Nothing is written to disk or the clipboard until you copy, save or drag out. Automatic copy
  and save exist, are off by default and apply to still captures.
- Screen Recording is requested at your first capture, not at launch; opening and editing images
  never needs it. Accessibility is requested only for automatic scrolling.
- The app is distributed outside the App Store without App Sandbox, because the sandbox forbids
  the Accessibility APIs that automatic scrolling needs
  ([ADR-002](docs/adr/0002-permission-and-sandbox-profile.md)).

Redaction protects the image you export. It cannot recall copies you exported earlier, including
automatic exports made before you redacted, or other apps' clipboard histories. Turn off
automatic copy, save and upload before capturing something sensitive.

## Optional GitHub upload

In Settings › GitHub, enter the owner/name of an existing **private** repository and a
fine-grained token restricted to it with **Contents: read and write**. Save the destination and
token, then enable and confirm automatic upload separately. The token stays in this app's
device-only Keychain, never in preferences or logs. Recortia creates no repository or token.

Still captures upload as sanitized PNG or JPEG under `screenshots/`, one commit per capture,
immediately and **before any later edit or redaction**. Images are limited to 8 MiB. Imports,
OCR-only captures and scrolling results are not uploaded. A successful upload shows a link in the
editor; private links need GitHub access.

Cancelling stops the batch's later actions. Once an upload has started, a timeout or cancellation can still leave it completed; Recortia
reports the uncertainty and does not retry by itself. Turning upload off or removing the token
does not delete remote copies or Git history. Keep the repository private
([ADR-006](docs/adr/0006-github-upload.md)).

## Build from source

You need stable Xcode 27.0 (27A266a, `stable_xcode_baseline` in `TOOLCHAIN.json`) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). Select the Xcode installation for each command
with `DEVELOPER_DIR`; an app named `Xcode.app` may still be a prerelease build, and
by default `scripts/doctor.sh` rejects any build other than the stable baseline.

```sh
scripts/check.sh --unsigned    # toolchain doctor, format lint, project freshness, tests, app build
scripts/e2e.sh --lang all      # scenarios through the real app in English and Portuguese
swift test --package-path Packages/RecortiaKit --filter <TestName>   # one test or suite
```

`scripts/check.sh` without `--unsigned` also builds the signed app and needs the maintainer's
signing identity. `scripts/e2e.sh` writes screenshots, `report.json` and `provenance.json` under
`.scratch/e2e/`; it needs an unlocked, idle desktop session, and it never touches the real screen,
general pasteboard, user defaults or Keychain. Releases are built by the maintainer with
`scripts/release.sh` from a `v<version>[-betaN]` tag.

`project.yml` owns the version and build number. After adding or moving source files, or
editing `project.yml`, run `xcodegen generate` and commit the regenerated project.

The code is split into `RecortiaApp/` (AppKit and SwiftUI app) and `Packages/RecortiaKit`:
`Domain` (document model, geometry, state machines), `Imaging` (decode, privacy renderer,
export, OCR, QR, stitching), `MacPlatform` (ScreenCaptureKit, permissions, sinks), `Features`
(feature models) and `RecortiaFixtures` (synthetic test inputs). Module boundaries are described
in [docs/architecture/module-contracts.md](docs/architecture/module-contracts.md).

## Known limitations

- Not yet validated on hardware: live capture on 1× and mixed-DPI multi-display setups, macOS 15
  and 26 hosts, the scrolling compatibility matrix, VoiceOver and input-method passes, and the
  performance budgets. On the build Mac, the first opening of the editor and of Settings took
  longer than the 50 ms target (PERF-02).
- Physical keyboard, Spaces and permission checks were not run on 0.12.2-beta1.
- Automatic scrolling scrolls downward only.
- There is no in-app updater; update through Homebrew or a new DMG.

Automated coverage, per-build gate results and installation evidence are recorded in
[BACKLOG.json](BACKLOG.json) and the records under [docs/specs/](docs/specs/). Accepted
security residuals are in [THREAT_MODEL.md](THREAT_MODEL.md).

## Documents

[SPEC.md](SPEC.md) (product contract) · [AGENTS.md](AGENTS.md) (engineering rules) ·
[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) and [BACKLOG.json](BACKLOG.json) (tasks) ·
[ACCEPTANCE_TESTS.md](ACCEPTANCE_TESTS.md) · [THREAT_MODEL.md](THREAT_MODEL.md) ·
[docs/adr/](docs/adr/) (decisions) · [CHANGELOG.md](CHANGELOG.md) ·
[CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md). The original planning handoff
is kept in [docs/handoff/](docs/handoff/).

## License

[MIT](LICENSE). The app bundle includes this license and the MIT notice of the pinned
KeyboardShortcuts package.
