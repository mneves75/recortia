# Handoff: Recortia 0.11.0 — "window does not appear" on launch, then Homebrew + DMG

Written 2026-10-07 21:41. Branch `feat/switcher-pins-0.11.0` (pushed up to `f3eadd1`; PR
[#14](https://github.com/mneves75/recortia/pull/14) open, not merged). Uncommitted work in the
tree (see Status). Older handoffs in `docs/handoffs/` (2026-10-05, 2026-10-07-1641,
2026-10-07-1832) are untracked and partly superseded; the 1641 one holds the full design detail
of the switcher/pin work.

## Goal

Latest owner message (after installing 0.11.0 build 17 locally): "window still does not appear
in macos; verify latest swift/swiftui skills I am running macos golden gate; when all finished;
update homebrew and dmg". It repeated the standing workflow: use the fable orchestrator skill,
always do adversarial review, research, plan, execute, improve/code-review if useful,
mneves-verify until satisfied, update all docs, bump version, CHANGELOG, commit, push, merge to
main, delete branch/worktree/unused `.scratch`, then release (beta tag `-betaN` for staging,
plain tag for prod) and update Homebrew + DMG.

## Status

Already shipped on the branch (committed and pushed): pins as normal-level windows (AltTab lists
them), `AppPresence` dynamic activation policy (⌘Tab/Dock while a window is open), pin
Copy/Drag Out, latency instrument, review fixes, 0.11.0 build 17 docs (`6ae23e0`, `35c28d0`,
`0966d36`, `5b4c1ef`, `f3eadd1`). Local install of build 17 in `/Applications/Recortia.app`
done 2026-10-07 (backup of 0.10.2 b16 at
`.scratch/local-install-0.11.0-20261007/Recortia-0.10.2-build16.app`).

Diagnosis of the new report (done, from unified log of the installed app, pids 42840 and 89991):
both runs launched, restored no windows ("Restoring windows … hasPersistentStateToRestore=0"),
the person opened the menu-bar menu (`_NSGlassEffectWindow makeKeyWindow` warning) and quit
~3 s later. No editor/pin/Settings window ever existed, so nothing could appear in ⌥Tab/⌘Tab.
Root cause: a menu-bar (`LSUIElement`) app shows nothing when opened. Also seen:
`_kLSApplicationWouldBeTerminatedByTALKey=1` (eligible for automatic termination). The owner's
"Open at login" is enabled (`SMAppService … status: 1`).

Half done (uncommitted, builds and passes E2E):
- `RecortiaApp/App/LaunchKind.swift` (new): `LaunchKind(openEvent:)` → `.loginItem` when the
  open-application event has `keyAEPropData == keyAELaunchedAsLogInItem`, else `.user` (nil
  event counts as user, so a missing marker shows a window rather than hiding one);
  `LaunchWindow.choose(onboardingPending:kind:)` → onboarding / settings / none.
- `RecortiaApp/App/RecortiaApp.swift`: `applicationDidFinishLaunching` calls
  `ProcessInfo.processInfo.disableAutomaticTermination(...)` and
  `model.launch(kind: LaunchKind(openEvent: NSAppleEventManager.shared().currentAppleEvent))`.
- `RecortiaApp/App/AppModel.swift`: `launch(kind:)` switches on `LaunchWindow.choose` (Settings
  on a user launch, onboarding first run, nothing for Open at login).
- E2E `launch-presentation` scenario in `RecortiaApp/E2E/Scenarios+Presence.swift`, registered in
  `E2EScenarios.swift` (was red against a stub, now green); project regenerated (pbxproj).

Not started: docs for this change (SPEC FR-01 launch sentence, ACCEPTANCE UX-02, ADR-007 launch
section, CHANGELOG, AGENTS/CLAUDE.md note), build bump to 18, Swift/SwiftUI skill review of the
changed surface for macOS 27 ("Golden Gate"), adversarial review (reviewer agent), full gate +
bilingual E2E, mneves-verify reverify, local reinstall + live check (launch shows Settings,
`lsappinfo` type Foreground, no TAL key), merge, release, Homebrew cask.

## Decisions

- Show Settings on a manual launch (same window a Dock click/relaunch already shows), stay silent
  for Open at login. Rejected: always show (annoying at login), silent whenever launch-at-login is
  enabled (owner has it enabled, so their bug would remain), a new home window (scope).
- Login detection: the `keyAELaunchedAsLogInItem` marker is not documented for
  `SMAppService.mainApp` launches; no source confirms it (searched). Chosen failure mode: if the
  marker is missing at login, Settings appears at login (visible, reportable). Verify at the
  owner's next real login.
- Measured with a scratch probe app (`open` launch): at `applicationWillFinishLaunching`
  `currentAppleEvent` is nil; at `applicationDidFinishLaunching` it is `oapp` with no prop;
  `NSApplicationLaunchIsDefaultLaunchKey` = 1 (cannot distinguish login, not used).
- Disable automatic termination at launch (log showed eligibility; a silent termination would
  kill global shortcuts).
- Earlier owner decisions still binding: pins normal-level (lose always-on-top); ⌘Tab only while a
  window is open; no capture sound; latency misses (editor 229–514 ms, first Settings 105–238 ms,
  onboarding borderline 36–66 ms) recorded and deferred in BACKLOG FP-028.
- Release path the owner asked for: production `v0.11.0` (no separate beta requested this time)
  with notarized DMG + cask. The 0.10.2 procedure: squash-merge PR, tag on main,
  `scripts/release.sh` (gate, notarize via `asc` profile, DMG), `gh release create`, bump cask in
  `mneves75/homebrew-tap` (`Casks/recortia.rb` version + sha256), then record the release in
  README/BACKLOG/CHANGELOG via a docs PR. The owner interrupted my first release attempt (a
  read-only `gh pr checks`/tap lookup) to report the window problem — fix that first.

## Dead ends

- `AltTab --help` / `--version` start a second AltTab instance that hangs; kill only that pid.
- dcg blocks: variable redirect targets, `rm -rf`, `mv` with `~` (even to Trash with a new name;
  only `mv <path> ~/.Trash/` standalone). Use the Write tool for files with dynamic paths.
- `ditto` into an existing app bundle merges (left the old `Contents/CodeResources` notarization
  ticket and the quarantine xattr); remove the old bundle first or diff/clean afterwards.
- Release scripts need a clean tree: untracked `docs/handoffs/` must be excluded temporarily via
  `.git/info/exclude` (comment on its own line; remove afterwards).
- Offscreen ordering of SwiftUI hosting windows in E2E recurses in layout (see 1641 handoff).

## Files

- `RecortiaApp/App/LaunchKind.swift`, `RecortiaApp/App/RecortiaApp.swift`,
  `RecortiaApp/App/AppModel.swift` — the launch fix.
- `RecortiaApp/E2E/Scenarios+Presence.swift` — `windowPresence`, `launchPresentation`.
- `RecortiaApp/App/AppPresence.swift` — activation policy rule (ADR-007).
- `docs/adr/0007-window-presence.md`, `SPEC.md` FR-01, `ACCEPTANCE_TESTS.md` UX-02, `CHANGELOG.md`
  0.11.0, `BACKLOG.json` (`current_candidate`, FP-026..028), `README.md` status line.
- `scripts/release.sh` (owner signing/notary), `.build/release/0.11.0-dev/` (dry-run output,
  large; delete when done).
- Scratch: `/private/tmp/claude-501/-Users-mneves-dev-PROJETOS-recortia/73766f04-bbef-498c-a680-0cbc4816b369/scratchpad/`
  (`launchprobe/`, `probe/qa-pid.py`, `recortia-log.txt`, `verify-brief.md`, `verify-result.md`).

## Verification

Prefix `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- `scripts/e2e.sh --lang en --only launch-presentation,window-presence > .scratch/e2e-launch.log 2>&1`
  → 2/2 passed (latest, uncommitted tree).
- At `0966d36`: `scripts/check.sh` all gates passed (577 package tests); `scripts/e2e.sh --lang all`
  41/41 EN and PT-BR. Must be rerun after the launch change (gate needs the change committed for
  project freshness).
- mneves-verify (gpt-6-astra via `codex-auto exec --worktree`): BLOCKED only on physical checks;
  one fresh full reverify remains.
- Installed-app check commands: `lsappinfo info -app dev.mvneves.Recortia | grep -o 'type="[A-Za-z]*"'`;
  `/usr/bin/log show --last 10m --style compact --predicate 'process == "Recortia"' | grep TAL`.

## Next steps

1. Update docs for the launch change (SPEC FR-01, ACCEPTANCE UX-02, ADR-007, CHANGELOG 0.11.0
   "Fixed: opening Recortia shows Settings", CLAUDE.md line), bump `CURRENT_PROJECT_VERSION` to 18
   in `project.yml` + `xcodegen generate`, format (`files=(${(f)"$(git status --short | awk '{print $2}' | grep '\.swift$')"}); xcrun swift format --in-place $files; xcrun swift format lint --strict $files`), commit with explicit paths, push.
2. Load `swiftui-pro` / `swiftui-expert-skill` / `swift-concurrency` (and macos-dev) and review the
   changed Swift/SwiftUI surface against macOS 27 SDK guidance; fix findings.
3. Adversarial review: `reviewer` agent on `git diff 5b4c1ef...HEAD` with the owner's latest
   message; fix findings.
4. `scripts/check.sh`, `scripts/e2e.sh --lang all` (redirect to file).
5. Reinstall locally (archive/export via `scripts/release.sh --dry-run`, remove old bundle cleanly,
   verify) and live-check: opening Recortia shows Settings, `lsappinfo` Foreground while open,
   accessory after closing, no TAL key in the log.
6. mneves-verify reverify (same brief + launch criterion).
7. Release (owner asked): squash-merge PR #14, tag `v0.11.0` on main, `scripts/release.sh`,
   `gh release create v0.11.0 <dmg> --latest` with CHANGELOG notes, bump the Homebrew cask
   (version 0.11.0, sha256 of the notarized DMG) in `mneves75/homebrew-tap`, `brew upgrade --cask
   recortia` to confirm, record release in docs via a PR, delete the branch and unused `.scratch`.

## Open questions

- Does the owner want a beta (`v0.11.0-beta1`) first, or production directly (their last
  message says "update homebrew and dmg")?
- After the next real login: does Settings pop up (login marker missing) or stay silent?
- Physical AltTab/⌘Tab/fullscreen-Space checks: still never run; owner stopped the probe once.

## Standing instructions from the owner

- English replies this session; lead final reports with numbered asks of the owner.
- Keep going without asking except for destructive or out-of-repo actions; put status notes in
  the same message as the next action.
- Always adversarial review; never claim unrun checks; positive control for every negative.
- Big changes: Sol plan + own plan, compare, ask; `reviewer` agent before done; `mneves-verify`
  with a different model for release/security.
- No backward compatibility; simplest implementation; layers; no stopgaps.
- Explicit-path Conventional Commits ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`;
  PR bodies end with the Claude Code line; never `--no-verify`.
- Recortia AGENTS.md: synthetic fixtures only, never read personal screen content, never change
  system settings, verify window behavior on the installed app, publish only on explicit request.
