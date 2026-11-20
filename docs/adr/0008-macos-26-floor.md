# ADR-008: Recortia requires macOS 26 from 0.15

**Status:** Accepted (2026-11-19)

## Context

ADR-001 set the deployment target to macOS 15.0 and gated newer APIs with `#available`. On
2026-11-19 the owner decided that 0.15 raises the minimum to macOS 26.0 and that macOS 15
support ends with 0.14 (SPEC.md §2). The modernisation audit at `b2726b4`
(`docs/specs/program-2026-11/evidence/modernisation-audit.md`) found little code that exists
because of the macOS 15 floor: no `#available` gate remains, and the only workarounds are the
hand-rolled `ObservationLoop` and a toolbar spacer. The audit checked each symbol below in the
Xcode 27.2 SDK interfaces; nothing in it was built or run on a macOS 26 host.

## Decision

1. **Deployment target:** macOS 26.0, arm64 only. `project.yml` (`deploymentTarget` and
   `MACOSX_DEPLOYMENT_TARGET`), `Packages/RecortiaKit/Package.swift` (`.macOS(.v26)`, tools 6.2)
   and `TOOLCHAIN.json` (`minimum_deployment_target`) carry the same value.
2. **No availability gates:** code uses no API newer than macOS 26 and no `#available`. An API
   introduced in macOS 27 waits for a later floor decision.
3. **Adopted with the floor (T1c):** `.strictMemorySafety()` for Imaging and MacPlatform,
   `Span`-based pixel access where it removes an unsafe pointer without copying, and
   `.onChange(of:initial:)` where an `.onAppear` and `.onChange` pair do the same work.
   `ToolbarSpacer` belongs to the editor refresh slice.

## APIs the floor unlocks

| Symbol | Available from | Use |
|---|---|---|
| `ToolbarSpacer` (SwiftUI) | macOS 26.0 | Editor toolbar grouping (editor refresh slice) |
| `Observations` (Observation) | macOS 26.0 | Candidate to replace `ObservationLoop`; measure first, because its first value arrives asynchronously |
| `.glassEffect`, `GlassEffectContainer`, `NSGlassEffectView` | macOS 26.0 | Waits for a design decision: glass makes `ChromeAppearance` nondeterministic |
| `RecognizeDocumentsRequest`, `DataDetection` (Vision) | macOS 26.0 | Measured by the automatic-redaction spike |
| `SCScreenshotManager.captureScreenshot`, `SCScreenshotConfiguration` | macOS 26.0 | Not adopted: adds only HDR, and its `fileURL` output writes raw pixels |
| `SupportedPlatform.MacOSVersion.v26` (PackageDescription) | tools 6.2 | The package floor |

Still out of reach at 26.0: `NSWindow.DidBecomeKeyMessage`, `NSApplication.DidBecomeActiveMessage`,
`AppIntentsTesting`, `LongRunningIntent` and `IntentExecutionTargets` (macOS 27.0).

## Alternatives rejected

- **Keep macOS 15 and gate each new API.** Two code paths for every adoption, and the macOS 15
  path has no test host either.
- **Raise the floor to macOS 27.** Drops every macOS 26 user for typed notification messages and
  App Intents testing, which nothing in 0.15 needs.

## Consequences

- People on macOS 15 stay on 0.14. A macOS 15 host that installs 0.15 is refused by the system
  (`LSMinimumSystemVersion` follows the deployment target).
- Raising the Homebrew cask's minimum macOS is an owner step at release.
- No test host runs macOS 26.x: the build Mac runs macOS 27.3. Support for macOS 26 rests on the
  SDK's availability checks until a macOS 26 host runs the app (SPEC.md §2).
- ADR-001's deployment-target decision is superseded; its history stays as written.
