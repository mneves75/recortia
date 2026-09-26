# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` is the canonical agent contract; read it first, then the task in `IMPLEMENTATION_PLAN.md`
and `BACKLOG.json`, and the matching requirements and cases in `SPEC.md` and `ACCEPTANCE_TESTS.md`.

## Commands

Every command needs the stable toolchain: `xcode-select` on the maintainer's Mac points to
Xcode-beta, so prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
(`scripts/*.sh` default to it). A bare `xcodebuild` builds with the beta and its evidence doesn't count.

- Full gate: `scripts/check.sh` (doctor, strict `swift format lint`, generated-project freshness,
  all package tests, signed Debug build); `--unsigned` without the signing identity.
- One package test: `swift test --package-path Packages/RecortiaKit --filter <TestNameOrSuite>`.
- End-to-end: `scripts/e2e.sh --lang all` runs the DEBUG scenario runner (`-RecortiaE2E <dir>`)
  through the real app and writes screenshots + `report.json` under `.scratch/e2e/`. The runner
  never touches the real screen, general pasteboard, user defaults, or keychain (in-memory settings
  and integrity key); keep it that way.
- Release (owner): `scripts/release.sh` → `.build/release/<version>/` (notarized DMG + manifest);
  `scripts/check-release-binary.sh` fails if the DEBUG-only E2E hook reached a binary.
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

## Repository facts

- GitHub `mneves75/recortia`, default branch `main`, squash-only PRs; push over SSH.
- Test fixtures are synthetic; never commit real screenshots or content-bearing logs.
- Owner-only steps: Screen Recording/Accessibility grants, Automation Mode for XCUITest,
  notarization credentials (`asc notarization`), and publishing.
- `docs/handoff/` is the frozen original handoff; do not update it.

## Agent skills

### Issue tracker

GitHub Issues in `mneves75/recortia` via `gh`; planned FP-xxx tasks stay in `BACKLOG.json`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five roles: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `CONTEXT.md` + `docs/adr/`. See `docs/agents/domain.md`.
