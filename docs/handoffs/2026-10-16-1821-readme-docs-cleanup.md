# Handoff: README rewrite, CHANGELOG squash, third-party name removal

## Goal

The owner asked for a correct README, all docs updated, no references to two named competing
commercial screenshot products, squashed commits and a squashed changelog; then "git add commit
push all"; then to merge PR #20, rewrite `main` into one commit, delete all tags and create one
new tag for the last version ("do it all").

## Status

- Docs work landed through PR #20 (squash merge `dd03993`).
- Then, at the owner's explicit choices: `main` was replaced by a single root commit (the
  `dd03993` tree with docs updated for the single release, plus this file). Ruleset `protect-main`
  (id 24042336) was disabled for the force-push and re-enabled right after. All 11 old releases
  and tags were deleted; `v0.12.2-beta1` was recreated as an annotated tag on the root commit and
  re-published as a regular release marked latest (the site's download button and the cask
  livecheck use `releases/latest`, which never resolves to a pre-release) with the same notarized
  DMG (SHA-256 `8b28f6df…bb4a942`). The cask `mneves75/tap/recortia` moved from 0.11.0 to
  0.12.2-beta1.
- Backups (all deleted at the owner's request later on 2026-10-16; the old history is gone):
  local branch `backup/main-pre-squash-20261016` (`dd03993`); bundle of all refs and tags
  `/Volumes/MARCUS_S7/ARCHIVE/dev-scratch/recortia/main-pre-squash-20261016.bundle`; every old
  release's notes and assets under
  `/Volumes/MARCUS_S7/ARCHIVE/dev-scratch/recortia/release-assets-pre-squash-20261016/`.
- Security gate: reused the production record for build commit `6822974`
  (`.scratch/security-gate/682297430ef2d8c139d6f116a8a33776059fb54f/`, WAIVED SEC-17/SEC-18); the
  shipped DMG is the same gated build. Reuse note in `.scratch/security-gate/republish-20261016.md`.

## Decisions

- "git squash commits": first landed as one squashed PR commit; then, on the owner's "do it",
  `main` itself was rewritten (owner chose: I toggle the ruleset; one new tag `v0.12.2-beta1` with
  a release; delete all old releases and tags and move the cask to the new release).
- The new release is not marked pre-release, so `releases/latest` (website CTA, cask livecheck)
  keeps working. Reversible with `gh release edit v0.12.2-beta1 --prerelease`.
- "git squash changelog": CHANGELOG.md now has one section per published release line (0.12.2-beta1,
  0.11.0, 0.10.2, 0.10.1, and 0.9.0-beta5 covering betas 1–5). Untagged candidates 0.9.1, 0.10.0,
  0.12.0, 0.12.1 are folded into the release that shipped them. Process/evidence narrative removed;
  it already lives in `BACKLOG.json`. Alternative offered: one section per minor.
- README is a product README: a version table (stable 0.11.0 build 18 on Homebrew; pre-release
  0.12.2-beta1 build 21), install, features with "(beta)" marking 0.12.2-only items, privacy, GitHub
  upload, build from source, known limitations, documents.
- The product names were replaced with generic wording ("other screenshot utilities"). SOURCES.md
  S01–S04 are marked "Withdrawn", not renumbered, so the S05+ citations stay valid. The feature
  comparison in `docs/specs/feature-discovery/reference-matrix.md` became a capability-gap table
  (same 40 rows, product column dropped, installed-bundle notes removed).
- The `docs/handoff/` frozen rule was overridden by the owner's instruction; names were edited out
  in place (nothing deleted), and the CLAUDE.md note was updated to match.
- New AGENTS.md rule: do not name competing commercial screenshot products in code, docs, commit
  messages or release notes; credit adopted open-source work (e.g. Tendedero) by name.
- `TOOLCHAIN.json` `stable_release_qualification: "blocked"` was left unchanged: its own rule allows
  changes only from an observed preflight.

## Dead ends

- In zsh, `git add -- $(git diff --name-only)` passes the whole list as one path. Use
  `git diff --name-only -z | xargs -0 git add --`.
- `echo ====` fails in zsh ("==== not found"); use other separators.
- The dashboard page accepts step status `in_progress`, not `running`.

## Files

- `README.md`, `CHANGELOG.md`: rewritten.
- `SPEC.md`, `SOURCES.md`, `docs/adr/0005-macos-default-shortcuts.md`,
  `docs/specs/{feature-discovery/spec.md,feature-discovery/reference-matrix.md,curved-arrows/spec.md,text-appearance/spec.md}`,
  `plans/feature-discovery-deep-review.md`, `docs/handoff/{COMPLETE_HANDOFF,START_HERE}.md`: names removed.
- `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `ACCEPTANCE_TESTS.md`, `THREAT_MODEL.md`,
  `IMPLEMENTATION_PLAN.md`, `.github/ISSUE_TEMPLATE/request.yml`: say evidence lives in BACKLOG.json and
  docs/specs/; naming rule; FP range FP-001…FP-037.
- `.dashboard/index.html` (git-excluded): progress dashboard; state `blocked` on the owner question.

## Verification

- `git grep` for the two product names, their domains and bundle IDs → no matches (exit 1). Before: 90
  matching lines in 12 tracked files at `f910d31`.
- Relative Markdown link check over tracked `.md` files: 0 broken.
- `DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=stable scripts/check.sh --unsigned`
  → `check: all gates passed` (511 package tests, 617 pt-BR strings, app and E2E builds).
- Independent `reviewer` agent: PASS with 5 findings, all fixed and folded into `76b67c7`. The
  `code-review` skill was not run (docs-only change).
- `gh pr checks 20 -R mneves75/recortia` → `check pass`.

## Next steps

1. Nothing pending. If anything above failed, the final report of this session says which step.
2. Done 2026-10-16: the owner had the backup branch, bundle and release-asset archive deleted.
3. Future releases: `scripts/release.sh` on a new `v<version>[-betaN]` tag; the cask and the
   README version line follow the release the owner publishes.

## Open questions

- Should `TOOLCHAIN.json` `stable_release_qualification` be updated after a new observed preflight?

## Standing instructions

- Owner rules for this repo: squash-only PRs; never name competing commercial screenshot products;
  commit with Conventional Commits plus the `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  trailer; force-push, history rewrite and merges need the owner's explicit confirmation.
