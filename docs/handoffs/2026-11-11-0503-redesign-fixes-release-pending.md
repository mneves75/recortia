# Handoff — redesign, review fixes and dark mode built; clean E2E, verify and release pending (2026-11-11 05:03)

Supersedes `docs/handoffs/2026-11-10-2216-editor-redesign-inspector-slice.md` (untracked, stale).

## Goal

Owner (Marcus), 2026-11-10/11, in his words: improve UI/UX, visuals and design; find and fix what
is broken, inconsistent, inefficient or no longer needed; fewer, deeper modules with smaller
interfaces; "support dark mode"; then "do it all", run `mneves-verify` and fix until clean, bump
the version, update all docs (CHANGELOG, AGENTS.md, CLAUDE.md, README), commit, push, merge to
`main`, delete branch/worktree/unused `.scratch`, tag the version and deploy to production
("AUTORIZADO ASAP"). He answered "yes to all, continue" three times to open decisions.

The main session (Fable 5.2) plans, specifies, reviews and integrates; implementation goes by
written brief to Opus 5.5 at medium effort (Agent tool, `model: opus`, `effort: medium`); reviews
of Opus builds go to Codex (`codex-auto exec -s read-only ... < brief`), never to Opus.

## Status

Everything is on branch `feat/editor-redesign`, PR #40 (https://github.com/mneves75/recortia/pull/40).
Local HEAD `4f8ec58` is 4 commits ahead of `origin` (the dark slice is not pushed). `main` is
untouched at `a069cbd`. No worktrees; branch `fix/review-2026-11` was merged in (`1d957f3`) and
deleted.

Built, committed, and `./init.sh check --unsigned` passing at `4f8ec58` (builder's run,
`.scratch/logs/dark-check.log`; the main session's own last gate run was at `1d957f3`):

- Slice 1: contextual inspector (Format/Image tabs). Slice 2: native window toolbar with Effects
  and Measure menu buttons. Slice 3: one-line tour copy, Settings with 7 content-tall panes.
  Slice 4: dark screenshot plus luminance check for every surface, dark checkerboard on screen
  only, window chooser sized to its list, scrolling HUD without the title band, tour window fixed
  at 580×615. Spec: `docs/specs/editor-redesign/spec.md`. Backlog: FP-045.
- Review fixes (FP-046, `docs/specs/code-review-2026-11/findings.md`): R-1 scroll-review Discard
  quits like the close button; R-2 alert title no longer denies earlier writes (also on the editor
  notice route); R-3 automatic batch frozen at capture and still gated by live checks; R-4 ACL kept
  on overwrite (reproduced first); cleanups C-1..C-7; `docs/handoff/COMPLETE_HANDOFF.md` removed;
  object list built in one pass; public declarations narrowed per module; one `LiveRecognition`;
  one import-failure mapping.
- Three independent Codex reviews (inspector, toolbar, original findings): no P1; all findings
  fixed test-first.

Not done:

- **No clean full bilingual E2E exists for the current tree.** Every full run so far was made while
  the Mac's screen was locked and/or another session sent real input, so foreground scenarios never
  ran: `last-window`, `settings` (click path), `automatic-save-settings`, `editor-toolbar`,
  `window-latency`, `capture-focus`, `editor-presentation`. Last full run: 48/54 per language at
  `4f8ec58`, console locked (`.scratch/e2e/20261111-024717-71233`) — offscreen checks only.
- The screen was reported **unlocked at about 05:00**; nothing has been run since.
- `mneves-verify`, version bump, docs, merge, tag and release: not started.

## Decisions

- UI first, one slice at a time; macOS 15.0 floor, standard system controls, no custom glass, no
  `#available` (owner, 2026-11-10).
- "Support dark mode" is read as: every surface right in the system's dark appearance, with
  evidence. No in-app appearance setting was added. (Main session's reading; owner has not
  objected.)
- Review fixes and redesign ship in one branch and one release (owner: "merge to main").
- R-3 freeze approved by the owner; R-4 fixed only because the ACL loss reproduced.
- Left out on purpose: the doubled GitHub token validation (credential path); per-frame text layout
  and double rendering (need measurement first).
- Tour: fixed 580×615 window instead of measuring pages at open, because measuring pushed the
  first frame to ~110 ms against the 50 ms budget. The budget was not changed.
- Help on entries inside the Effects/Measure menus cannot be observed (SwiftUI sets no tooltip on
  bridged menu items); the menu button shows the active tool's help instead.
- Next version: 0.14.0, build 28 (current `project.yml`: 0.13.0, build 27).

## Dead ends

- Running two E2E runners at once: they fight for the foreground window. Every `scripts/e2e.sh`
  call must hold the directory lock `.scratch/e2e.lock` (`mkdir` to take, `rmdir` to release).
- E2E with the screen locked (`ioreg -n Root -d1 | grep -c '"IOConsoleLocked" = Yes'` prints 1):
  offscreen scenarios pass, foreground ones fail at the owned foreground fixture. Such runs are
  void for those scenarios; do not fix code against them.
- The stop hook runs `./init.sh check --unsigned` at every turn end and fails while an agent has
  uncommitted work in the checkout; wait with a blocking shell loop instead of ending the turn.
- `dcg` blocks appending to `.git/info/exclude`, shell `eval`, and likely `rm -rf`; `scratch clean`
  refuses entries nested under `.scratch/e2e`.

## Files

- `docs/specs/editor-redesign/spec.md` — design authority, slices 1–4 as built.
- `docs/specs/code-review-2026-11/findings.md` — findings, triage and per-item resolution.
- `BACKLOG.json` — FP-045 (redesign) and FP-046 (review fixes, `awaiting_manual_validation`).
- `RecortiaApp/Editor/EditorInspectorView.swift`, `EditorRootView.swift`, `EditorWindowManager.swift` — inspector and toolbar.
- `RecortiaApp/Onboarding/OnboardingView.swift`, `RecortiaApp/Settings/*` — tour and Settings.
- `RecortiaApp/Capture/HostingPanel.swift` — shared panel; commit `37092ee` changes how panels are
  centred (found by the dark slice, outside its brief, isolated so it can be dropped; its test does
  not go through `present`).
- `RecortiaApp/E2E/Scenarios+Appearance.swift` — `ChromeAppearance` dark/light chrome check.
- `docs/specs/autosave-menu-bar/release-0.13.0.md` — how the last release was done and recorded.
- `scripts/release.sh` — release pipeline (needs tag `v<version>` at HEAD, clean tree, Developer ID
  identity, provisioning profile, `asc` notary profile).
- `.dashboard/index.html` — progress dashboard (untracked; `.dashboard/` is not git-excluded).

## Verification

- `./init.sh check --unsigned` — passed at `4f8ec58` (builder), at `1d957f3` and `9bf1159` (main
  session). One first-run failure of `TextLayoutConcurrencyTests` (nativeFont, rounded) at `4f8ec58`
  passed on rerun: the open F-1 font incident, log `.scratch/logs/dark-check-run1-fontflake.log`.
- Full E2E, to run now that the screen is unlocked, under the lock, redirected to a file:
  `L=.scratch/e2e.lock; until mkdir "$L" 2>/dev/null; do sleep 15; done; scripts/e2e.sh --lang all --unsigned > .scratch/logs/final-e2e.log 2>&1; rc=$?; rmdir "$L"; exit $rc`
  — never run clean on this tree. `capture-focus` and `editor-presentation` need the owner idle.
- `window-latency`: reported editor first frame ~500–600 ms and Settings ~150 ms against 50 ms, in
  locked runs only. Compare unlocked on this branch and on `main` before calling it a regression
  (the bridged toolbar is the suspect).

## Next steps

1. Check `ioreg -n Root -d1 | grep -c '"IOConsoleLocked" = Yes'` prints 0. Another Claude session
   ("redesign-retineo-ui", socket `uds:/tmp/cc-socks/32022.sock`) was promised the desktop first
   for about five minutes: take `.scratch/e2e.lock`, send it "desktop is yours", release when it
   says done (or after a reasonable wait if it does not answer).
2. Push `feat/editor-redesign`, then run the full bilingual E2E command above. Read every failure;
   fix real ones test-first through an Opus agent.
3. Run `window-latency` unlocked on `main` (temporary worktree) and on the branch; if the toolbar
   regressed the editor's first frame, fix it before release.
4. Review the dark screenshots (`.scratch/e2e/20261111-022500-37445/{en,pt-BR}/*-dark-*.png`) and
   decide whether to keep `37092ee`.
5. Send the slice 3 + slice 4 diff (`6ec8458..HEAD`, excluding the merge) to a Codex read-only
   review; fix findings.
6. Invoke the `mneves-verify` skill; fix until its verdict is clean.
7. Release prep: `project.yml` to 0.14.0 build 28, `xcodegen generate`, CHANGELOG section, README
   version lines, AGENTS.md/CLAUDE.md where behavior or commands changed, BACKLOG candidate record;
   update PR #40's description; commit, push.
8. Run the `mneves-security` deploy gate on the exact commit (binding precondition).
9. Merge PR #40 (squash-only repository), tag `v0.14.0` on the merge commit, run
   `scripts/release.sh`, publish the GitHub release, update the Homebrew cask as 0.13.0's record
   describes, install and verify. Then delete the branch and the uncited `.scratch/e2e` runs.

## Open questions

- Shortcut recorders in Settings show "Record Shortcut" printed twice in offscreen screenshots: is
  that visible in the real Settings window?
- Is "support dark mode" satisfied by following the system appearance, or is an in-app
  Light/Dark/System setting wanted?
- Keep the shared-panel centring fix `37092ee`? (Default: keep, after an on-screen check.)

## Standing instructions

- Start every reply with `Marcus,`. Keep going without asking unless blocked or before something
  destructive; put status notes in the same message as the next action.
- Tests first; fix code, not tests; never accept evidence from a locked or contended run.
- Do not name competing screenshot products in code, docs or commits.
- Commit small and often to the working branch; the merge, tag and production release are
  authorized by the owner for this task ("AUTORIZADO ASAP"), with the security gate first.
