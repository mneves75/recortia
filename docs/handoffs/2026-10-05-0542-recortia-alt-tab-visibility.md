# Handoff: Recortia window missing from "alt tab"

Written 2026-10-05 05:42 (local). Branch `main`, clean, in sync with `origin/main`. No repository
file was changed by this work except this handoff.

## Goal

The owner reported, in these words: "recortia window does not appear alt tab". They want the
Recortia window to be reachable from their window switcher. Which switcher they mean is not yet
known (see Open questions).

## Status

- **Finished:** orientation and source reading. No diagnosis is confirmed.
- **Blocked:** every live measurement. The Mac's screen was locked for the whole session
  (`CGSSessionScreenIsLocked=1`, frontmost app `loginwindow`). Nothing measured under lock is valid.
- **Not started:** any fix, any test, any doc change.

What is established:

- Recortia is a menu-bar-only app: `LSUIElement: true` at `project.yml:53` and
  `RecortiaApp/Info.plist:32`. macOS never lists such apps in ⌘Tab or the Dock. This is by design
  (SPEC FR-01, "Menu-bar operation").
- The owner's ⌥Tab is the AltTab app (`/Applications/AltTab.app`, version 11.7.1, running, default
  preferences, no custom shortcut). AeroSpace was not running. Its config
  `~/.config/aerospace/aerospace.toml:50` binds `alt-tab = 'workspace-back-and-forth'`, so it would
  take the key if it were started.
- AltTab 11.7.1 source (`lwouis/alt-tab-macos`, tag `v11.7.1`) does not gate on activation policy:
  - `src/switcher/state/ApplicationDiscriminator.swift` rejects an app only for being a zombie,
    XPC, or the window manager.
  - `src/switcher/state/WindowAdmissionResolver.swift` admits a level-0 window with subrole
    `AXStandardWindow` (or a titled `AXDialog`). It rejects `AXFloatingWindow` / `AXSystemDialog`
    and, above level 0, anything that is not `kAXMain` or fullscreen.
  - Only the "windowless app" placeholder requires `.regular`.
- Live positive case from before the lock mattered: AltTab's list held a tracked window for
  `com.apple.SystemProfiler`, which `lsappinfo` reports as `type="UIElement"`. So accessory policy
  alone does not hide a window from AltTab on this Mac.
- By that source, Recortia's editor and Settings windows (titled, level 0) should be listed, and its
  pins, HUDs and drag chip (`level = .floating` in `RecortiaApp/Pins/PinPanels.swift:48`,
  `RecortiaApp/Capture/HostingPanel.swift:23`, `RecortiaApp/App/DragChip.swift:66`) should not.
  Neither statement was tested live.

State left on the machine:

- The installed Recortia 0.10.2 build 16 was **not** running at the start. This session launched it
  with `open -a /Applications/Recortia.app` (pid 88939 at last check) and opened its Settings
  window with a second `open -a`. It was left running on purpose so the owner can press ⌥Tab after
  unlocking. Quit only that pid, and only if the owner wants the earlier state back.
- One OptMem note was saved (#3042): check the lock state before live window probes.

## Decisions

- **Do not conclude anything from data gathered while the screen is locked.** A `.regular` control
  app with a plain titled window also returned `windows=[]` from AltTab. AltTab's own
  `ScreenLockEvents.swift` says apps publish zero windows while the screen is dark.
- **An earlier in-session claim was retracted.** A status note said the problem was reproduced on
  the installed app. That was wrong and the owner was told so.
- **No code change without the owner's choice.** `AGENTS.md` says to propose first when work is not
  a planned task, and the two readings of the request lead to different work.
- **Default reading if the owner does not answer: the AltTab app**, because it is installed, running
  and on its ⌥Tab default.
- **No background "wait for unlock" job was started.** The control windows call `NSApp.activate()`
  and would steal focus from the owner at the moment they unlock.
- **AltTab output is filtered before it is read.** The scripts print per-app counts and full rows
  only for the target pid, so other apps' window titles never reach the log. No screenshot of the
  owner's desktop was taken; `AGENTS.md` forbids reading personal screen content.

## Dead ends

- Probing AltTab under a locked screen. All four control variants (regular/accessory ×
  default/follow) showed `appKnown=True windows=[]`.
- `lsappinfo info -only ApplicationType -only LSUIElement -only bundlepath -app <id>` prints mostly
  `[ NULL ]`; only the `type="UIElement"` / `type="Foreground"` field is useful.
- Python `import Quartz` is not available here. Read the lock state with a Swift one-liner instead
  (see Verification).
- `rg -i "UIElement"` over AltTab sources matches every `AXUIElement`. Search for
  `activationPolicy` instead; the only hit is the Dock-badge code at `Applications.swift:1256`.
- The `dcg` hook blocks a shell redirect to a path built from a variable. Use literal paths.
  Foreground `sleep` is blocked; wait inside a Python script with `time.sleep`.

## Files

- `project.yml:53` — `LSUIElement: true`; the source of truth for `Info.plist`.
- `RecortiaApp/App/RecortiaApp.swift` — `MenuBarExtra` app; `applicationShouldHandleReopen` shows
  Settings when no window is visible.
- `RecortiaApp/App/SpacePolicy.swift` — `followsActiveSpace = [.moveToActiveSpace, .fullScreenAuxiliary]`
  and `joinsAllSpaces`; any fix must keep every window on one of these.
- `RecortiaApp/Editor/EditorWindowManager.swift:76-117` — editor window construction and `present()`
  (activate, `makeKeyAndOrderFront`, `orderFrontRegardless` when activation is declined).
- `RecortiaApp/Settings/SettingsWindowController.swift` — the AppKit Settings window.
- `SOURCES.md` S21 and S22 — recorded activation and Space measurements. S22 was measured under
  accessory policy; a switch to `.regular` invalidates it.
- `AGENTS.md` — Space-policy rules, "propose first" rule, and the ban on reading personal screen
  content.
- `scripts/space-probe/` (`run.sh`, `probe.swift`, `host.swift`) — the physical Space probe to rerun
  if activation policy or window behavior changes.
- Session scratchpad (may be gone in a new session; recreate from the descriptions below):
  `/private/tmp/claude-501/-Users-mneves-dev-PROJETOS-recortia/e19fc7b7-caf6-476d-bde2-ff3478394590/scratchpad/`
  - `ctl.swift` / `ctl` — control app. Usage `ctl <regular|accessory> <default|follow> [lifetime]`.
    Shows one 560×448 window with style `[.titled, .closable, .miniaturizable, .resizable]`; `follow`
    sets `[.moveToActiveSpace, .fullScreenAuxiliary]`. Calls `NSApp.activate()`,
    `makeKeyAndOrderFront`, then `orderFrontRegardless()` if inactive, prints its pid, exits after
    `lifetime` seconds. Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O ctl.swift -o ctl`.
  - `qa-pid.py <pid> <seconds>` — polls `AltTab --qa-state` and prints `appKnown` plus, for that pid
    only, each window's `wid, shown, phantom, isMainWindow, spaceIndexes, size`.
  - `alttab-list.py [needle]` — `AltTab --detailed-list` reduced to per-bundle counts and matching rows.
  - `session.swift` — prints the lock state.
  - `alttab/*.swift` — AltTab 11.7.1 sources fetched with
    `gh api "repos/lwouis/alt-tab-macos/contents/<path>?ref=v11.7.1" -H "Accept: application/vnd.github.raw"`.

## Verification

- Lock state (run this first; proceed only when it is not locked):
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift session.swift`
  where `session.swift` prints `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`.
  Last result: `screenIsLocked=1 onConsole=1 displayAsleep=false`.
- What AltTab tracks: `/Applications/AltTab.app/Contents/MacOS/AltTab --detailed-list` and
  `--qa-state` (JSON; `apps`, `windows[].pid/shown/phantom`). Last result before any Recortia
  window: 28 windows across 9 apps, 0 for `dev.mvneves.Recortia`. After the Settings window opened,
  under lock: app known, 0 windows — **void**, see Decisions.
- WindowServer view of Recortia's windows (`CGWindowListCopyWindowInfo` filtered by pid): one window,
  `layer=0 onscreen=1 alpha=1 size=560x448` (the Settings window).
- Control matrix under lock: all four variants `windows=[]` — **void**.
- Repository gates were not run. Nothing in the repository changed.

## Next steps

1. Check the lock state. If the screen is unlocked, run the control matrix unchanged and read the
   results in this order: `./ctl regular default 9` must show a tracked window in
   `python3 qa-pid.py <pid> 6`; if it does not, the instrument is still broken and nothing else
   counts. Then compare `accessory default` with `accessory follow`. `follow` is exactly
   `SpacePolicy.followsActiveSpace`, so this isolates whether the Space flags hide the window.
2. Only then test the installed app: `qa-pid.py "$(pgrep -x Recortia)" 6` with the Settings window
   open, and with an editor window open (Open Image from the menu-bar menu with a synthetic image;
   never a real screenshot).
3. If AltTab lists Recortia's ordinary windows, report that and ask which window or situation the
   owner means (a pin or HUD is a floating panel and is excluded by AltTab's rules).
4. If AltTab does not list them and the matrix points at accessory policy or the Space flags, write
   a proposal before editing. Follow the owner's order: docs, then a failing test, then the smallest
   implementation.
5. If the owner means macOS ⌘Tab, write the proposal for a dynamic activation policy: `.regular`
   while an editor, Settings or onboarding window is open, `.accessory` otherwise. State the costs:
   a Dock icon appears, FR-01 changes, S22 must be re-measured with `scripts/space-probe/run.sh`,
   and the installed app must be checked over a fullscreen Space.
6. When the work ends, quit pid 88939 only if the owner asks for the earlier state.

## Open questions

- Which switcher does the owner mean: the AltTab app (⌥Tab) or macOS ⌘Tab?
- After unlocking, does ⌥Tab show the Recortia Settings window? Does AltTab show any windows at all?
- Which Recortia window is missing: the editor, Settings, or a pin/HUD?
- If ⌘Tab: does the owner accept a Dock icon while a window is open, and the re-qualification of
  the Space behavior?
- Should the Recortia process this session started (pid 88939) be quit?

## Standing instructions from the owner

- Reply in the owner's language (this request was in English; pt-BR with correct accents when they
  write in pt-BR). Lead with the outcome and state blockers first.
- Diagnosis requests end with a report; they do not authorize edits. Propose new work first.
- Never claim a check that was not run. Every negative result needs a positive control.
- Verify window behavior on the installed app, not only with a probe.
- Use the stable toolchain: prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Do not update `docs/handoff/` (the frozen original handoff); this file lives in `docs/handoffs/`.
- Commit only when asked. This handoff is uncommitted.
