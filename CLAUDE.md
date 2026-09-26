# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` is the canonical agent contract; read it first, then the selected milestone/task in
`IMPLEMENTATION_PLAN.md` and `BACKLOG.json`, and the matching requirements and cases in `SPEC.md`
and `ACCEPTANCE_TESTS.md`. This file does not authorize implementation or change approval boundaries.

## Current state

- Documentation-only bundle: no Xcode project, Swift package, scripts, or tests exist yet.
  The `swift test` / `xcodebuild` lines in `AGENTS.md` are intended shapes, not working commands.
  Do not scaffold a project to make a command succeed; FP-004 creates it after M0 approval.
- Initial authority is planning only (FP-001 inventory → M0 plan → owner approval).
- Git: own repository, default branch `main`, remote `origin` = private GitHub
  `mneves75/framepin-app` over SSH. `main` rejects force-pushes, deletion, and merge commits.
- `TOOLCHAIN.json` null fields are filled only from an observed Mac preflight, never guessed.

## Handoff copy

- `COMPLETE_HANDOFF.md` concatenates every bundle document except `CLAUDE.md`. Mirror edits to
  those documents there, or it goes stale.

## Architecture (SPEC §6–8)

- One app (`FramepinApp/`) plus one local package `Packages/FramepinKit` with targets
  `Domain` → `Imaging` → `MacPlatform`; Domain imports no AppKit/SwiftUI/ScreenCaptureKit.
  All paths are proposed, not existing.
- Every save, clipboard write, and drag-out consumes an immutable `ShareSnapshot` from the
  sanitizing export pipeline; nothing outside it touches a raw `ImageAsset`. Redaction replaces
  source pixels before any neighbor-sampling filter, resample, or magnifier.
- Async results carry request ID, document revision, and privacy epoch; the UI discards any
  result whose values no longer match.
- Capture, scroll, and export are explicit state machines (SPEC §6); performance numbers in
  SPEC §10 are targets, not measurements.

## Agent skills

### Issue tracker

GitHub Issues in private `mneves75/framepin-app` via `gh`; planned FP-xxx tasks stay in `BACKLOG.json`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five roles: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `CONTEXT.md` + `docs/adr/`. See `docs/agents/domain.md`.
