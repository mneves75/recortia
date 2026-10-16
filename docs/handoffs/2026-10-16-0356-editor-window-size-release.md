# Handoff: editor window size fix, test reduction, 0.12.2-beta1 release and install

> **COMPLETED 2026-10-16. Do not re-run anything below.**
> - PR #18 was squash-merged as main 6822974.
> - The `mneves-security` gate returned WAIVED (SEC-17, SEC-18); records are in
>   `.scratch/security-gate/682297430ef2d8c139d6f116a8a33776059fb54f/`.
> - Tag `v0.12.2-beta1` was pushed. The notarized pre-release is published at
>   https://github.com/mneves75/recortia/releases/tag/v0.12.2-beta1.
> - The app is installed in /Applications from the published DMG.
> - Docs PR #19 was merged as f910d31.
>
> The status below is the pre-release snapshot and is now historical. The open follow-ups are
> in the BACKLOG `current_candidate` entry and in the gate report's section 4.

## Goal

The owner (pt-BR speaker; reply in pt-BR with correct accents, keep identifiers in English) asked:

1. "fix when after screenshoting something, the window always appears in different width / sizes;
   when all done, 1. approved, install on this macos". "1. approved" approves the release plan:
   `mneves-security` deploy gate on the exact main commit → annotated tag `v0.12.2-beta1` →
   `scripts/release.sh` (gate, notarized DMG via `asc`, manifest) → `gh release create
   v0.12.2-beta1 <dmg> --prerelease` → verify → install on this Mac.
2. "Só escreva um teste se ele realmente falhar quando o código estiver quebrado de uma forma que
   importe. everything else is unnecessary bloat. try to reduce ate least 40% of tests on this project".

Repo: `/Users/mneves/dev/PROJETOS/recortia` (Recortia, native macOS 15+ screenshot app, Swift 6.4,
Swift Testing), GitHub `mneves75/recortia`, squash-only PRs, real users.

## Status

- DONE: window-size fix (commit cbe1153).
- DONE: test reduction, 779 → 553 test functions (−29.0%) plus 87 parameter cases. 40% NOT reached.
  The three different-model pruning passes each stopped at 28–32% of their partition, with
  reasons. The owner was told.
- DONE: independent GPT-6 Astra review (high). It found three sole-CI guards; all three were
  restored in f6e85c4. The re-review returned "approve".
- DONE: PR #18 https://github.com/mneves75/recortia/pull/18. CI succeeded on head ab02bec
  (run 38858778587).
- LOCAL, NOT PUSHED: 1b31c3f "docs(specs): state the commit each mutation batch ran on"
  (branch is ahead 1).
- WAITING (the blocker): full bilingual native E2E. A background waiter
  `/private/tmp/claude-501/-Users-mneves-dev-PROJETOS-recortia/39c3c498-55c0-4a8e-865f-637ee250c5cb/scratchpad/e2e-when-idle.sh`
  (task b1j1jcbal) runs `scripts/e2e.sh --lang all --unsigned` from the main checkout. It starts
  once the console is unlocked, HIDIdleTime is ≥120 s and no `RecortiaE2E` process is running.
  It gives up after 8 h. Its log is
  `.scratch/editor-window-size-20261016/e2e-full-dfba173.log`; the filename is stale, so cite the
  commit from the run's `provenance.json`. The Mac was locked at 2026-10-16 ~03:50, and the owner
  was asked to unlock it and leave it idle for ~15 min. A waiter task does not survive into a new
  session. If no E2E dir newer than `.scratch/e2e/20261016-010223-32099` exists, start a waiter
  again with the same script.
- NOT STARTED: merge, security gate, tag, release, publish, install, cleanup, memory update.

## Decisions

- Window size: remembered last live-resized content size (`Preferences.editorContentSize:
  Size<DesktopSpace>?`, optional, no schema bump, sanitized by
  `EditorWindowSizing.rememberable`), else default 1100×720. It is clamped to 0.92 of the visible
  frame, with minimum 980×560 and maximum side 32768. It is recorded in
  `windowDidEndLiveResize` via `settings.update`.
- Pruning rule (also written as an AGENTS.md test-policy line): keep a unit test only if it fails
  when a break matters to a user, to data or to security. E2E overlap may remove a unit test, but
  data-loss, privacy and security guards keep a unit test, because hosted CI
  (`.github/workflows/ci.yml` → `scripts/check.sh --unsigned`) runs NO native E2E. 64 of the
  removed tests cite E2E coverage.
- The author kept these against the pruning passes: `FileSinkTests.refusesOverwrite`,
  `SettingsStoreTests.storesNoContent`,
  `test_marker_in_main_executable_is_rejected_by_app_and_by_executable_path`, and restored
  `ScrollMatcherMemoryTests.measuresEquivalence`.
- Restored after the review: `ExportCoordinatorTests.cancelAutomaticBatch` and
  `ScrollSessionModelTests.screenPermissionDenied`. `ClipboardSinkTests.replacesPriorContents`
  now asserts the exact PNG bytes.
- Added test `EditorExportTests.saveOverwriteFollowsConfirmation`. The original suite missed
  mutations F18 and F19 (unconfirmed save overwrite).
- Hold the merge until the E2E passes (advisor). The README status paragraph still says
  "The stable gate (720 tests)" and "48/48 per language", and needs the new numbers (511 package
  tests, 42 script tests, the E2E result). BACKLOG needs an entry. Both must land in the PR before
  merge, so the tag and the security gate run on the commit that carries the docs.
- Version stays 0.12.2/build 21: build 21 was never distributed. No v0.12 tags exist; latest is
  v0.11.0. The Homebrew cask follows stable releases only, so do not update it for a beta.
- Model routing (owner rule): Opus implements. Reviews go to Codex `gpt-6-astra` (high for
  review, xhigh for plan/advice) via `/Users/mneves/bin/codex-auto exec -s read-only -m
  gpt-6-astra -c 'model_reasoning_effort="high"' -C <repo> -o <out.json> - < <brief>`.
  agent-admission allows at most 4 concurrent Codex runs and exits 75 when full: retry in a loop
  with sleep 90.

## Dead ends

- dcg blocks: redirects to variable or dynamic paths (use literal paths), `git rm -f` (use
  `git rm --cached` + `/usr/bin/trash`), `git branch -D`, `git restore`, backtick heredocs,
  `python3 -c` with `subprocess.run`, and piping `git` output into a python heredoc.
- zsh does not word-split `$files`; use `xargs` with a file list.
- `git -C <wt> checkout HEAD@{0}` resolves the worktree's own HEAD; use explicit SHAs.
- Native E2E fails ("owned foreground fixture state timed out") when the owner is active, and
  cannot run while the screen is locked.

## Files

- `Packages/RecortiaKit/Sources/Features/EditorWindowSizing.swift`: sizing rules.
- `RecortiaApp/Editor/EditorWindowManager.swift`: controller init and `windowDidEndLiveResize`.
- `RecortiaApp/E2E/Scenarios+EditorWindowSize.swift`: E2E `editor-window-size`.
- `docs/specs/test-reduction/README.md`: reduction record (table, rules, mutation net, out-of-scope).
- `CHANGELOG.md`: "### Changed" (test reduction) and "### Fixed" (window size) under Unreleased.
- `AGENTS.md`: test-policy line after "Do not remove or weaken a failing test…".
- `.scratch/editor-window-size-20261016/`: evidence (cited by the spec). It holds the gate log
  `gate-unsigned-dfba173.log`, the E2E logs, and `test-reduction/` (decisions, briefs, Astra
  JSONs, `mutations.json`, `mutate_run.py`, reports).
- `.scratch/wt-mutate`: detached mutation worktree (task-created; currently at cbe1153). Remove it
  at the end.
- Scratchpad tools: `/private/tmp/claude-501/-Users-mneves-dev-PROJETOS-recortia/39c3c498-55c0-4a8e-865f-637ee250c5cb/scratchpad/`
  (`count_tests.py`, `mutations-draft.py`, `mutate_run.py`, `dash.py` for `.dashboard/index.html`).
- `docs/handoffs/`: untracked and not ours. Never modify other files there.

## Verification

Prefix every command with `DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=stable`.

- `scripts/check.sh --unsigned`: passed at dfba173 (509 package tests, 42 script controls,
  617 pt-BR strings, app and E2E builds). HEAD now has 511 package tests: Domain 38,
  Features 245, Imaging 126 (7 OCR, skipped in CI), MacPlatform 102.
- `python3 -I <scratchpad>/count_tests.py /Users/mneves/dev/PROJETOS/recortia cbe1153 HEAD` →
  779 → 553.
- Mutation net: 55 mutations. The reduced suite catches all of them: 31 at 9dd9b54, 21 at
  a195955, 3 at f6e85c4. The original suite catches all except F18 and F19.
- CI: PR #18 run 38858778587 succeeded on ab02bec.
- The last full bilingual E2E (on 002f8b8, an earlier commit) took ~8 min of run time.

## Next steps

1. Check whether the E2E ran: `ls -t .scratch/e2e | head -3` and
   `tail -20 .scratch/editor-window-size-20261016/e2e-full-dfba173.log`.
   - If it has not run, rerun the waiter (literal-path redirect to that log, run in background).
   - If it failed only with the foreground-fixture timeout, rerun once. Any other failure is a real
     finding on the window change: diagnose it.
2. After the E2E passes:
   - Update README's status paragraph (511 package tests, 42 script tests, the E2E result, the
     window fix) and add a BACKLOG entry.
   - Update the PR #18 body: remove "Not yet verified", and change 509 to 511.
   - Commit, push, wait for exact-head CI.
   - `gh pr merge 18 --squash --match-head-commit <sha> --delete-branch`.
   - Check main CI.
3. Invoke the `mneves-security` skill (deploy gate) on the exact main SHA. Keep its records in
   `.scratch/security-gate/` and never clean them.
4. Make a clean worktree of the main SHA. `release.sh` refuses a dirty tree, and the untracked
   `docs/handoffs/` dirties the main checkout. Then:
   - Create the annotated tag `v0.12.2-beta1` (local is enough; `release.sh` uses
     `git describe --exact-match`).
   - Run `scripts/release.sh` from that worktree. It runs the signed `check.sh` and notarizes with
     `asc`; never print keys. Its output goes to `<worktree>/.build/release/0.12.2-beta1/`.
     Preserve that directory before removing the worktree. A failed run keeps the reservation and
     burns the label.
   - `git push origin v0.12.2-beta1`.
   - `gh release create v0.12.2-beta1 <dmg> --prerelease --notes ...`.
   - Check the live manual and site (owner lesson).
5. Install:
   - `pgrep -x Recortia` first; if it is running, do not kill it.
   - Back up `/Applications/Recortia.app` (0.12.0/build19).
   - Install from the notarized artifact.
   - Verify: `codesign --verify --deep --strict`, version/build 0.12.2/21, Hardened Runtime,
     "Recortia Developer ID" profile and keychain access group, no `get-task-allow`.
   - Report whether a relaunch is needed.
6. Cleanup:
   - `git worktree remove .scratch/wt-mutate` and the release worktree, then `git worktree prune`.
   - `git branch -d fix/editor-window-size`.
   - Keep `.scratch/editor-window-size-20261016/`.
   - Update project memory (`/Users/mneves/.claude-mvnevesbrb/projects/-Users-mneves-dev-PROJETOS-recortia/memory/`)
     and the dashboard.
   - Final report in pt-BR, leading with what the owner must do. Include their command for the
     173 old E2E runs: `! cd ~/dev/PROJETOS/recortia && xargs -I{} /usr/bin/trash .scratch/e2e/{} < .scratch/full-source-review-20261015/uncited-e2e-runs-from-earlier-sessions.txt`.

## Open questions

- Only the owner can unlock the Mac and leave it idle for the native E2E. Everything after step 1
  waits on that.
- Out of scope, not acted on: MacPlatform public API with no production caller
  (`DesktopGeometry.selection`, `display(containing:in:)`, point conversion,
  `MacPlatform.RepeatRegion`, `SettingsStore.resetToDefaults`). The owner may want it removed in
  a separate change.
