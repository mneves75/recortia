# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` is the canonical agent contract; read it first, then the task in `IMPLEMENTATION_PLAN.md`
and `BACKLOG.json`, and the matching requirements and cases in `SPEC.md` and `ACCEPTANCE_TESTS.md`.

## Commands

Every command needs the stable toolchain: `xcode-select` on the maintainer's Mac points to
Xcode-beta, so prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
(`scripts/*.sh` default to it). Xcode-beta MCP diagnostics may supplement a requested review;
beta compilation does not replace the stable-toolchain release gates.

- Full gate: `scripts/check.sh` (doctor, E2E-isolation and parsed Release-entitlement regression controls, strict `swift format lint`, generated-project freshness,
  all package tests, signed Debug build, pt-BR coverage of every extracted string, E2E target build); `--unsigned` without the signing identity.
- One package test: `swift test --package-path Packages/RecortiaKit --filter <TestNameOrSuite>`.
- End-to-end: `scripts/e2e.sh --lang all` runs the DEBUG scenario runner (`-RecortiaE2E <dir>`)
  through the real app and writes screenshots + `report.json` under `.scratch/e2e/`. The runner
  never touches the real screen, general pasteboard, the app's user defaults, or keychain (in-memory
  settings and integrity key; shortcut assignments only in its own `dev.mvneves.Recortia.E2E` domain,
  cleared at start, with a fake list of macOS shortcuts and a Carbon-free probe) and installs no
  global shortcut handler; keep it that way.
  `AppModel`'s message presenter defaults to native alerts; the harness records those messages
  instead of entering a modal loop or opening System Settings. This does not prove real alert
  interaction, TCC prompting, or live permission behavior.
- Release (owner): tag `v<version>[-betaN]`, then `scripts/release.sh` → `.build/release/<version[-betaN]>/`
  (fresh checkout, gate, notarized DMG, manifest with dependencies); `--dry-run` skips tag/gate/notary;
  `scripts/check-release-binary.sh` fails if the DEBUG-only E2E hook reached a binary.
- Local signed installation and version updates: follow `AGENTS.md`'s artifact checks and
  version-ownership rules. Current candidate and installation evidence live in README and BACKLOG.
- After adding or moving source files, or editing `project.yml`: `xcodegen generate` and commit
  the regenerated `Recortia.xcodeproj` (never hand-edit the pbxproj).
- Format: `xcrun swift format --in-place --recursive <paths>` (config in `.swift-format`).

## Architecture

- `RecortiaApp/` (MainActor default isolation): composition root in `App/` (`AppServices.live()`
  adapts Features protocols to Imaging/MacPlatform; `AppModel` owns feature models and windows),
  plus `Editor/`, `Capture/`, `Pins/`, `Scroll/`, `Settings/`, `Onboarding/`, and DEBUG-only `E2E/`.
- `Packages/RecortiaKit`: `Domain` (typed geometry spaces, `Document`, `DocumentSession` undo and
  privacy epoch, state machines, `ShareSnapshot` with a `package` init) → `Imaging` (bounded
  decode, `ImageStore` — the only holder of raw pixels — `PrivacyRenderer`, `ExportPipeline`, OCR,
  QR, `ScrollStitcher`) → `MacPlatform` (ScreenCaptureKit, permissions, sinks, input) → `Features`
  (main-actor models + service protocols). `RecortiaFixtures` generates synthetic test inputs and
  must never import Imaging.
- Invariants: every save/copy/drag/pin goes through `ExportPipeline` → `ShareSnapshot`
  (`ShareSnapshotConstructionTests` enforces it); secure masks fill source pixels before any
  resample or effect (RED suite with planted controls); async results are accepted only while
  request identity, revision, and privacy epoch still match.
- Contracts between modules: `docs/architecture/module-contracts.md`. Decisions: `docs/adr/`.
- Region-selection panels receive keyboard focus without activating the app; synthetic
  foreground/activation checks supplement the physical shortcut/Space matrix (CAP-01).
- Capture completion shows an ordinary fullscreen-auxiliary editor even when cooperative
  activation is delayed or declined. Layout precedes canvas focus. Keep `editor-presentation`
  in bilingual native E2E; its synthetic window state does not qualify physical Spaces.
- Window presence (ADR-007): `RecortiaApp/App/AppPresence.swift` makes the app regular while a
  switchable window (normal/modal level, shown or minimized; pins included) exists and accessory
  otherwise. Present ordinary windows through `AppPresence.activate()`; pins are normal-level
  windows so AltTab lists them. Keep `window-presence` in bilingual E2E.
- All desktops: `RecortiaApp/App/SpacePolicy.swift` owns window Space behavior (windows follow
  the active Space, panels join all Spaces; `SpacePolicyMonitor` is a safety net for framework
  windows like About) and `ScreenChoice.swift` picks screens. Settings is an AppKit window
  (`Settings/SettingsWindowController.swift`), not a SwiftUI `Settings` scene, whose window
  switched Spaces in 0.10.1. `scripts/space-probe/` is the physical probe; rerun it, and check
  the installed app over a fullscreen Space, when changing any of these files.
- Quit goes through `AppModel.shouldTerminate()`; unexported edits need confirmation.
  Imports admit synchronously (`ImageImporter.admit`) before reading any bytes, drops included.
- Pipe-free E2E: redirect `scripts/e2e.sh` output to a file; a pipe stays open for the
  runner watchdog's 300 s sleep.
- GitHub upload consent is session-versioned; capture-to-batch-to-sink carries the original
  identity, so revocation and restoring the same preferences cannot revive an old intent.
- Import admission and canvas keyboard ownership follow the corrective contract in `AGENTS.md`.
  `ImageImporter` is shared by the app and every editor; drop providers run only after admission.
  Keep the real-app synthetic `import-admission` and `canvas-focus` scenarios in EN/PT-BR runs.

## Repository facts

- GitHub `mneves75/recortia`, default branch `main`, squash-only PRs; push over SSH.
- Test fixtures are synthetic; never commit real screenshots or content-bearing logs.
- Owner-only steps: Screen Recording/Accessibility grants, Automation Mode for XCUITest,
  notarization credentials (`asc notarization`), the "Recortia Developer ID" provisioning
  profile that Release signing needs for the keychain access group, and publishing.
- `docs/handoff/` is the frozen original handoff; do not update it.

## Agent skills

### Issue tracker

GitHub Issues in `mneves75/recortia` via `gh`; planned FP-xxx tasks stay in `BACKLOG.json`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five roles: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Read `docs/adr/` and `docs/architecture/module-contracts.md`; consult root `CONTEXT.md` if it
exists. See `docs/agents/domain.md`.
