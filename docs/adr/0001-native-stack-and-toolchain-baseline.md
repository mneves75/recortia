# ADR-001: Native stack and toolchain baseline

**Status:** Proposed — awaiting owner review (FP-001)
**Date:** 2026-09-26
**Requirements:** FR-01, FR-14 · **Verification:** REL-01

## Context

SPEC.md §2 selects a native Swift app on stable Xcode 27, Swift 6 language mode, and a macOS 15.0
deployment target, subject to a local preflight. FP-001 ran that preflight on the maintainer's Mac.
Two observations change how that baseline is applied:

- `xcode-select -p` returns `/Applications/Xcode-beta.app/Contents/Developer` (Xcode 27.2, build
  27B5019j). A stable Xcode 27.0 (27A266a) is installed alongside it at `/Applications/Xcode.app`.
- The host runs macOS 27.2 (26B5091g). Its software-update catalog is `index-27seed`, so it is a seed
  (pre-release) OS.

## Decision

1. **Language and UI:** Swift 6.4 compiler in Swift 6 language mode. SwiftUI for settings and chrome;
   AppKit for capture overlays, the editor canvas, panels, and window lifecycle.
2. **Frameworks:** ScreenCaptureKit for capture, Vision for OCR/QR, Core Graphics and ImageIO for
   rendering and encoding. No third-party imaging, OCR, or capture code.
3. **Deployment target:** macOS 15.0, arm64 only. The installed SDK supports every capture and OCR
   primitive the 0.1 scope needs at that target (table below). Newer APIs are availability-gated,
   never a reason to raise the target.
4. **Toolchain:** stable Xcode 27.0 (27A266a), selected per command with
   `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The global `xcode-select` setting is
   left unchanged because other projects on this Mac use it. FP-004's `scripts/doctor.sh` must fail
   when the active Xcode build differs from `TOOLCHAIN.json`.
5. **Evidence boundary:** compile and deterministic test results from this seed-OS host count.
   Performance (SPEC §10) and signed-release evidence must come from a stable-OS host.
6. **Dependencies:** KeyboardShortcuts is the only M1 dependency candidate. Sparkle waits for M6.

## API availability evidence

Checked against `MacOSX27.0.sdk` headers and Swift interfaces, then confirmed by typechecking a probe
file with `swiftc -typecheck -swift-version 6 -target arm64-apple-macos15.0`. The probe passed. A
negative control that calls `captureImage(in:)` without a gate failed with "only available in
macOS 15.2 or newer", which shows the typecheck enforces availability.

| Symbol | Available from | Use at the 15.0 target |
|---|---|---|
| `SCScreenshotManager.captureImage(contentFilter:configuration:)` | macOS 14.0 | Primary still-capture path |
| `SCScreenshotManager.captureImage(in:)` | macOS 15.2 | Gate with `#available`, or skip |
| `SCScreenshotManager.captureScreenshot(…)` / `SCScreenshotConfiguration` | macOS 26.0 | Gate; HDR output is out of v1 scope |
| `SCContentFilter.pointPixelScale`, `.contentRect`; `SCShareableContent.info(for:)` | macOS 14.0 | Geometry contract inputs |
| `SCStreamConfiguration.showsCursor` / `.ignoreShadowsSingleWindow` / `.captureResolution` | 12.3 / 14.0 / 14.0 | Capture options |
| `SCStreamConfiguration.includeChildWindows`, `SCContentFilter.includeMenuBar` | macOS 14.2 | Window/display capture |
| `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` | macOS 10.15 | Just-in-time permission |
| Vision `RecognizeTextRequest`, `DetectBarcodesRequest` (Swift API) | macOS 15.0 | OCR/QR; languages queried at runtime |
| `@concurrent` | Swift 6.2+ language feature | Accepted at the 15.0 target |
| Swift Testing `Attachment` + `AttachableAsImage` (`_Testing_CoreGraphics`) | macOS 11.0 | Image evidence in RED/EXP tests |

## Dependency resolution (upstream, read 2026-09-26)

| Package | Release | Tag → commit | License | Minimum OS | Status |
|---|---|---|---|---|---|
| sindresorhus/KeyboardShortcuts | 3.1.0 (2026-09-11) | `772133d9dbe800fdac0473226822994c5c162c58` | MIT | macOS 10.15 | Candidate for FP-006; code review pending |
| sparkle-project/Sparkle | 2.10.0 (2026-09-13) | `eef1a539a373c1f1a320624b1130fc5de7b2e100` | GitHub reports `NOASSERTION` | macOS 12 | Deferred to FP-024; license and notices review required |

## Consequences

- Every documented build or test command sets `DEVELOPER_DIR`. An agent that runs a bare
  `xcodebuild` builds with the beta and produces evidence that doesn't count.
- A stable-OS benchmark host is needed before FP-023. Options: a macOS VM on this Mac, a second Mac,
  or moving this Mac off the seed program.
- Support claims for macOS 15 and 26 need test hosts running them (SPEC §2). None exist yet.
