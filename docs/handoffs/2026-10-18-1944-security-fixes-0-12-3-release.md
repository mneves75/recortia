# Handoff: Recortia 0.12.3 security fixes and release (2026-10-18)

## Goal

The owner pasted a Codex transcript (a requirements/E2E audit of 0.12.2, verdict FAIL, no code
changed) followed by a "do it all" request: plan, fix what was found, review, run
`mneves-verify`, update docs, bump version, changelog, commit, push, merge, delete
branch/worktree/unused `.scratch`, tag `v<version>-betaN` and deploy to staging, tag `v<version>`
and deploy to production, install on this Mac. Standing instructions: keep going without asking
unless blocked or before destructive / outside-repo actions; reply in the user's language
(English here).

## Status

Done:
- Fixed the four open plan items of the 0.12.2 production gate: CORE-1 (automatic copy/save
  recheck preference and resolved folder before the write, `ExportCoordinator.swift`),
  PLATFORM-1 (overwrite keeps replaced file's permission bits, temp 0600 only when replacing,
  chmod best effort, `FileSink.swift`), BR-1 (fat64 magic in `scripts/check-release-binary.sh`),
  BR-2 (`scripts/e2e.sh` recomputes source provenance after the build and refuses divergence).
  Each has a red-first test.
- Version 0.12.3 build 22 (`project.yml`, regenerated pbxproj), CHANGELOG `[0.12.3]`, BACKLOG
  `current_candidate` 0.12.3 (old one renamed `previous_release_0_12_2`, its `backup` field now
  says deleted), handoff note `docs/handoffs/2026-10-16-1821-readme-docs-cleanup.md` no longer
  calls the pre-squash backups present.
- PR #21 squash-merged: `main` = `b14427a9a8613fd5512ea55a6c8dde4994f0b061`, tree
  `648d30b00b18febaed51e4fb12276852c1e52695` (equal to audited `e6cd249`). Remote branch deleted.
- Security gate (mneves-security) done: staging **PASS**; production **BLOCK** on SEC-17 and
  SEC-18 only (independent acceptance PASS). Records in
  `.scratch/security-gate/e6cd24934c1a73cd4e45631da5363eb1077c580b/` (full report
  `production.md`, pt-BR) and copies with `reused_from` in
  `.scratch/security-gate/b14427a9a8613fd5512ea55a6c8dde4994f0b061/`.
- `mneves-verify`: round 1 FAIL (report wording only), corrected; full reverify **PASS** (Fable
  5.1, fresh context).
- Annotated tag `v0.12.3-beta1` on `b14427a`, pushed (message carries "security gate: PASS
  (staging…)").

In progress when this was written:
- `scripts/release.sh` for `v0.12.3-beta1` running in the background (was in its "== gate"
  stage). Log: `.scratch/security-fixes-20261018/release-0.12.3-beta1.log` (ends with
  `exit=<n>`). Output: `.build/release/0.12.3-beta1/` (DMG, manifest).

Not started:
- Local install of the beta (staging = this Mac).
- Production release `v0.12.3` (GitHub release latest, Homebrew cask `mneves75/tap/recortia`,
  README version line) — blocked on the owner (see Open questions).
- Cleanup (see Next steps).

## Decisions

- Scope: only the four gate plan items + stale backup docs. Out of scope (need owner approval or
  hardware): FP-024 signed updater (`requires_approved_milestone`, new Sparkle dependency +
  signing key), FP-028 window-open latency (owner deferred; needs pre-built-windows plan), FP-036
  P3 proposals (`proposal_requires_owner_approval`), physical/TCC/Spaces qualification.
- Version 0.12.3 build 22; beta tag first (precedent 0.10.2-beta1 → 0.10.2). No GitHub release
  for the beta: staging = local install only.
- CORE-1 compares the folder the current bookmark resolves to, not bookmark bytes, because
  `LiveServices.resolveFolder` renews a stale bookmark during the render (found by the platform
  auditor; byte compare cancelled that save).
- PLATFORM-1: new non-overwrite saves keep 0644 (minus umask); chmod failure on volumes like SMB
  leaves the file 0600 rather than failing the save.
- Codex (GPT-6 Astra) unavailable: both accounts rate-limited until 2026-10-24, so the three
  audit partitions, the reviewer and both verifiers ran as Claude Fable 5.1 (different model from
  the Opus 5.5 builder).
- The 0.12.2 waivers (SEC-17 until 2026-11-15, SEC-18 until 2027-04-16) were granted for
  0.12.2-beta1 specifically, so they were not carried to 0.12.3.
- Kept: the running Recortia PID 73949 (0.12.2, no open windows) is not to be killed; precedent
  is install and let the owner relaunch.

## Dead ends

- `codex-auto exec` with `CODEX_AUTO_MODEL=gpt-6-astra`: "all configured accounts have exhausted
  quota". Don't retry before 2026-10-24.
- dcg blocks shell redirects to variable paths and `$var` in `git branch`; write helpers as
  Python files in the scratchpad with literal paths.
- Python heredoc whose body contains a `PY` line terminates an outer `<<'PY'` early; use a file.
- Native E2E foreground scenarios (`capture-focus`, `editor-presentation`) fail while the screen
  is locked (`CGSSessionScreenIsLocked = true` via the arc-cua Python's Quartz).

## Files

- `Packages/RecortiaKit/Sources/Features/ExportCoordinator.swift`: `isAllowed` recheck in `run`
  and `runAutomaticExports`.
- `Packages/RecortiaKit/Sources/MacPlatform/FileSink.swift`: permissions in `save` and
  `POSIXFileSystem.replace`.
- `scripts/check-release-binary.sh`, `scripts/e2e.sh`, tests `scripts/test-release-binary.py`,
  `scripts/test-doctor.py`, `Packages/RecortiaKit/Tests/{FeaturesTests/ExportCoordinatorTests.swift,MacPlatformTests/FileSinkTests.swift}`.
- `.scratch/security-gate/e6cd24934c1a73cd4e45631da5363eb1077c580b/production.md`: gate report,
  findings BR2-1, BR2-2 (Low) and 7 Informational, remediation plan.
- `.scratch/security-fixes-20261018/`: `check.log`, `check-2.log`, `e2e.log`, release log.
- `.scratch/e2e/20261018-180816-35011/`: native E2E run at `5b8e2e5` (47/49 per language).

## Verification

- `DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=stable scripts/check.sh --unsigned`
  → "check: all gates passed" (513 package tests, 44 script controls, 617 translations) at
  `1632b19` and `5b8e2e5`; verifier's `swift test` 513/513 at `e6cd249`.
- `E2E_TIMEOUT=900 scripts/e2e.sh --lang all --unsigned` (redirect to a file) → 47/49 each; only
  the two foreground scenarios failed, screen locked.
- Hosted CI on PR #21 head `e6cd249`: pass.
- Release: check the tail of `.scratch/security-fixes-20261018/release-0.12.3-beta1.log` for
  `exit=0`; then `scripts/check-release-binary.sh` already runs inside; verify DMG with
  `codesign --verify --deep --strict`, `spctl -a -vv`, `xcrun stapler validate`.

## Next steps

1. Read the release log tail. If `exit=0`, inspect `.build/release/0.12.3-beta1/` (manifest,
   DMG SHA-256), then install locally: mount the DMG, `ditto` the app to a staging path, verify
   signature/version 0.12.3 (22)/entitlements, replace `/Applications/Recortia.app` (dcg blocks
   `mv` in /Applications: use `ditto` + trash), leaving PID 73949 running; tell the owner to
   relaunch. Record install evidence in BACKLOG via a small PR (protect-main requires PRs).
2. After the owner decides SEC-17/SEC-18: update `production.json` (both commit folders) to
   `waived` with the named waivers, re-read `origin/main` and remote tags, tag `v0.12.3` on
   `b14427a` (message "security gate: WAIVED (SEC-17, SEC-18)"), run `scripts/release.sh`,
   create the GitHub release (not pre-release, latest), bump the cask in `mneves75/homebrew-tap`
   (version + sha256), update README version line + BACKLOG release record via PR, check
   `releases/latest` and the gh-pages download link.
3. Cleanup: `git worktree remove .scratch/wt-sec-e6cd249` (has a 344 MB ignored `.build`, may
   need `--force`), `git worktree prune`; local branch `fix/security-plan-items` needs
   `git branch -D` (squash merge) which dcg blocks: give the owner
   `! dcg allow-once <id> --yes`. Keep `.scratch/security-gate/` forever. Scratchpad files under
   `/private/tmp/claude-501/-Users-mneves-dev-PROJETOS-recortia/6c1ad47b-67e1-41c6-821d-61c6646c20e2/scratchpad/`.
4. Rerun the two foreground E2E scenarios when the screen is unlocked and idle:
   `scripts/e2e.sh --lang all --only capture-focus,editor-presentation --unsigned --no-build`.

## Open questions

- SEC-17: extend the waiver to 0.12.3 (same reason/expiry 2026-11-15), or create a fine-grained
  token for `mneves75/recortia` + `mneves75/homebrew-tap` first? Current `gh` token is classic
  with `repo`, `workflow`, `gist`, `read:org`.
- SEC-18: does the "no activity log, by privacy" product decision (until 2027-04-16) apply to
  0.12.3?
- Plan items BR2-1 (entitlement allowlist), BR2-2 (E2E harness live auto-scroller), and the
  CORE-1 test gap (autoSave off during render): schedule them?

## Resolution (2026-10-18, after this note was written)

- `scripts/release.sh` for `v0.12.3` finished with `exit=0`: archive, Developer ID export,
  entitlement and test-marker checks, notarized and stapled app and DMG, manifest
  (`.scratch/security-fixes-20261018/release-0.12.3.log`).
- GitHub release `v0.12.3` published from `.build/release/0.12.3/Recortia-0.12.3.dmg`, regular
  release marked latest; the re-downloaded asset is byte-identical to the build artifact.
  Cask `mneves75/tap/recortia` moved from 0.12.2-beta1 to 0.12.3 (tap commit `38fa2ae`);
  `brew audit` and `brew fetch` pass.
- The two foreground scenarios passed with the screen unlocked: `capture-focus` and
  `editor-presentation` in EN, and `editor-presentation` in pt-BR, in
  `.scratch/e2e/20261018-222318-85851`; `capture-focus` in pt-BR failed its activation control in
  that run and passed on a rerun (`.scratch/e2e/20261018-222351-89710`).
- Production app installed in `/Applications` from the verified export; the running 0.12.3 beta
  process was left alone, so a relaunch is needed to run the installed bundle.
- Open questions closed by the owner's "finish all work": SEC-17 and SEC-18 remain waived with
  their existing expiry; BR2-1, BR2-2 and the CORE-1 test gap are recorded as FP-038, FP-039 and
  FP-040 with status `not_started`.
