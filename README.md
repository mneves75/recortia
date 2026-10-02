# Recortia

A native, local-first macOS screenshot utility: capture, annotate, redact for real, and share —
from the menu bar, with optional user-controlled GitHub upload and no local screenshot archive.

**Status:** beta source candidate (0.10.0-beta3, build 12). The v1 features FR-01…FR-13 in `SPEC.md` are built, and FR-14 except its
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

The current 0.10.0-beta3 candidate (app version 0.10.0, build 12) was installed locally on
2026-10-02 from commit `2069d91` after the signed stable gate, synthetic EN/PT-BR E2E,
independent reviews and PR CI passed. Developer ID archive/export, strict signature,
Hardened Runtime, parsed distribution entitlements and provisioning profile checks passed.
All 33 installed files match the export; build 10 was preserved intact. The installation
procedure did not launch or terminate the app. Physical shortcuts, actual displays/Spaces,
TCC, clean-user launch and notarized/public distribution remain unverified.
Evidence: `.scratch/local-install-build12-20261002/installation.json`.

The build-11 candidate adds shared import admission across documents/layers and clears transient
Space-to-pan input when the canvas loses keyboard ownership. It has not been installed or published.
The previous local Developer ID-signed
0.10.0-beta1 candidate (app version 0.10.0, build 10) was installed on 2026-10-01 from this
working tree after the stable gate and synthetic EN/PT-BR E2E passed. The exported and installed
binary hashes match; signature, Hardened Runtime, distribution entitlements and provisioning
profile were verified. Build 9 and its running process were preserved; quit and reopen after
saving current documents to test build 10. No notarization or public release is claimed.
Evidence: `.scratch/local-install-github-build10-final-20261001/verification.txt` and
`installation.txt`; E2E: `.scratch/e2e/20261001-013242/`.

Previously, the local Developer ID-signed
0.9.1-beta3 candidate (app version 0.9.1, build 9) was installed on the maintainer's Mac on
2026-09-30 from commit `49047c7`. Independent verification confirmed that all installed files
match the approved export, with valid signature, distribution entitlements and bundled licenses.
The previous build 7 was preserved. The app was not launched by the installation procedure and
has not been notarized. [PR #5](https://github.com/mneves75/recortia/pull/5) merged the source changes.

Earlier build-10 installation and build-11 verification evidence remains historical and is recorded in
`BACKLOG.json`; live capture and production qualification remain pending. See
[Validation status](#validation-status).

## What it does

- **Capture** a region, a display, or a chosen window; delayed capture; repeat the last region.
  Recortia's own windows are excluded; regions stay on one display. Starting another capture hides
  existing Recortia windows during selection and capture, then restores them without closing
  documents or taking focus. Still and scrolling workflows cannot overlap.
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

- Capture, editing and recognition run on your Mac. Network requests occur only when you
  explicitly enable optional GitHub upload, which is off by default.
- Nothing is written to disk or the clipboard until you choose Copy, Save, or drag out
  (auto-copy and auto-save exist and are off by default).
- Screen Recording is requested at your first capture, not at launch. Opening and editing images
  never needs it. Accessibility is requested only for automatic scrolling.
- Public DMGs are distributed outside the App Store, signed with Developer ID and notarized, without
  App Sandbox, because the sandbox forbids the Accessibility APIs automatic scrolling needs
  ([ADR-002](docs/adr/0002-permission-and-sandbox-profile.md)).

Redaction protects the exported image. It cannot recall copies you exported earlier or other
apps' clipboard histories.

## Optional GitHub auto-upload

In Settings › GitHub, enter the owner/name of an existing **private** repository and a
fine-grained token restricted to it with **Contents: read and write**. Save the destination/token,
then separately enable and confirm automatic upload. Tokens stay in this app's device-only
Keychain, never preferences/logs. No repository/token is created for you.

Still captures upload immediately **before later edits or redaction**, as sanitized PNG/JPEG
under `screenshots/`, creating a commit per capture. Images are limited to 8 MiB. Imports,
OCR-only captures and scrolling results do not auto-upload. Successful uploads show an editor
link; private links require GitHub access and have no promised expiry.

Cancellation stops later batch actions. Once PUT begins, timeout/cancellation may leave a
completed upload; the app reports uncertainty and does not retry automatically. Disabling upload
or removing the token does not delete remote copies or Git history. Keep the repository private.
Provider-level retries preserve their intent ID; a new capture creates a new intent.

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

Build 12 corrects shortcut selection activation and permanently invalidates revoked GitHub
upload intents. Synthetic coverage checks an external foreground application, activation
notifications and AppKit keyboard dispatch; it does not prove physical hotkeys, multiple
monitors or actual fullscreen/Space transitions. Build-11 results below are historical.
The final build-12 signed `scripts/check.sh` passed 517 package tests, 12 Python controls,
517 translated strings, formatting/project freshness and both Debug builds. A fresh different-model
behavior verifier ran the complete suite once: 27/27 scenarios, 672 assertions and 56 reported
screenshots per language; all assertions passed and reported PNGs were valid. Evidence:
`.scratch/capture-shortcut-build12-20261001/check.log` and `.scratch/e2e/20261001-230940/`.

Automated: Swift Testing suites for every module, including the redaction metamorphic tests
(RED-01…RED-04) with planted-leak controls, import hardening (IO-01), export container inspection,
OCR accuracy on a 104-sample EN/PT-BR corpus, and scroll stitching with held-out calibration, plus
the end-to-end scenario runner (27 scenarios in English and Brazilian Portuguese). The build-11
stable-Xcode signed gate passed 517 package tests, 12 Python controls, 517 translated strings,
project freshness, strict formatting, and both Debug builds. A fresh different-model verifier
independently executed the full synthetic suite: 26/26 scenarios, 603 assertions, and 55 screenshots
per language. A separate fresh behavior-only context ran the two corrected flows, passed 159
assertions per language, and inspected all 22 generated renders without reading implementation.
Evidence: `.scratch/e2e/20261001-171230/` (full suite) and
`.scratch/e2e/20261001-171639/` (independent behavior). Earlier build-9/build-10 results remain
historical evidence in `BACKLOG.json`; they are not evidence for the build-11 artifact.

Security: source reviews and synthetic regressions cover redaction, export boundaries, input
limits, asynchronous freshness, and cancellation. The beta1 and beta3 corrections are listed in
`CHANGELOG.md`; accepted residuals and the limits of live verification remain in `THREAT_MODEL.md`.
No confirmed source defect remains after independent Standards/Spec correction review. Dedicated
security execution is blocked: this host cannot enforce the required memory limit for its isolated
harness. Ordinary repository regression gates passed; that does not replace that containment proof.
These checks do not establish that all platform behavior or security risks have been eliminated.

Release evidence: PR #3 and its post-merge unsigned CI passed for the beta1 source; PR #5 and
its pre-merge and post-merge CI passed for beta3. The local 0.9.1 build 9 archive/export succeeded with stable
Xcode 27.0; strict signature verification,
Hardened Runtime, the embedded provisioning profile, the protected Keychain access group,
absence of the debug entitlement, and byte equality between the export and installed bundle
were checked independently against the installed bundle. Build 7 was preserved; launch after replacement and
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
