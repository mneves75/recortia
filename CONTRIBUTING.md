# Contributing to Recortia

Thanks for helping. Recortia is a native, local-first macOS screenshot utility; please read
`SPEC.md` (product contract), `AGENTS.md` (engineering boundaries), and `THREAT_MODEL.md` first.

## Setup

- macOS 26.6 or later with stable Xcode 27.0 (27A266a, see `TOOLCHAIN.json`). If `xcode-select`
  points to another Xcode, prefix commands with `DEVELOPER_DIR=<stable Xcode.app>/Contents/Developer`.
- XcodeGen; the project freshness check fails without it.
- After changing `project.yml` or adding/moving source files, run `xcodegen generate` and commit
  the regenerated project.

## Gate

```sh
scripts/check.sh            # doctor, format lint, project freshness, package tests, signed app build
scripts/check.sh --unsigned # same, without the maintainer's signing identity
```

Run one package test: `swift test --package-path Packages/RecortiaKit --filter <TestName>`.

## Version and distribution

Update version/build metadata in `project.yml`, regenerate with `xcodegen generate`, and keep
the candidate label in CHANGELOG and BACKLOG consistent; README's version table changes only when a
release is published. Record test and installation evidence in BACKLOG, with the version it
applies to. Generated app `Info.plist` values must match the
new metadata before committing; run the repository gate after regeneration.

Signed local installs use the archive/export and artifact checks in `AGENTS.md`. Public
distribution uses the tagged `scripts/release.sh` pipeline. A local install, a notarized DMG,
and a clean-user launch are separate verification steps; BACKLOG records which have run.

## Rules that reviews enforce

- Tests first (Swift Testing). A bug fix starts with a test that fails on the bug.
- Every save, copy, drag, and pin goes through `ExportPipeline` and a `ShareSnapshot`. Changes to
  masks, geometry, magnifier caches, export formats, or clipboard types must pass the RED suite.
- No telemetry, clipboard polling, private frameworks, or permission shortcuts. The approved
  opt-in GitHub uploader (ADR-006) is the only image-network destination; every transfer uses
  a sanitized `ShareSnapshot`, sealed consent, and bounded redirect-free HTTPS.
- New-document imports and editor layers share one admission slot. Acquire file, clipboard,
  and drop-provider bytes after admission; retain the slot until canceled work has exited.
- Never commit real screenshots or content-bearing logs; fixtures are generated in code.
- Swift 6 language mode; no `@unchecked Sendable`, `nonisolated(unsafe)`, `try!`, or `fatalError`
  in production paths.
- Every user-facing string is localized in English and Brazilian Portuguese.
- Conventional Commits.

By contributing you agree that your contributions are licensed under the MIT License.
