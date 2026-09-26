# Contributing to Recortia

Thanks for helping. Recortia is a native, local-first macOS screenshot utility; please read
`SPEC.md` (product contract), `AGENTS.md` (engineering boundaries), and `THREAT_MODEL.md` first.

## Setup

- macOS 26.6 or later with stable Xcode 27.0 (see `TOOLCHAIN.json`). If `xcode-select` points to a
  beta, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- `brew install xcodegen` if you change `project.yml` (regenerate with `xcodegen generate`).

## Gate

```sh
scripts/check.sh            # doctor, format lint, project freshness, package tests, signed app build
scripts/check.sh --unsigned # same, without the maintainer's signing identity
```

Run one package test: `swift test --package-path Packages/RecortiaKit --filter <TestName>`.

## Rules that reviews enforce

- Tests first (Swift Testing). A bug fix starts with a test that fails on the bug.
- Every save, copy, drag, and pin goes through `ExportPipeline` and a `ShareSnapshot`. Changes to
  masks, geometry, magnifier caches, export formats, or clipboard types must pass the RED suite.
- No network code, telemetry, clipboard polling, private frameworks, or permission shortcuts.
- Never commit real screenshots or content-bearing logs; fixtures are generated in code.
- Swift 6 language mode; no `@unchecked Sendable`, `nonisolated(unsafe)`, `try!`, or `fatalError`
  in production paths.
- Every user-facing string is localized in English and Brazilian Portuguese.
- Conventional Commits.

By contributing you agree that your contributions are licensed under the MIT License.
