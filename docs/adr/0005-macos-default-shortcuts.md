# ADR-005: Default shortcuts mirror the macOS Screenshot app

**Status:** Accepted (2026-09-27). Amends SPEC.md FR-01, which asked for no default shortcuts.

## Context

Until 0.9.0-beta4 every global shortcut was user-assigned. The owner asked for the same defaults
as the macOS Screenshot app, so that people who already type ⇧⌘3 and ⇧⌘4 need no setup.

Those combinations belong to macOS (symbolic hot keys 28–31 and 184 in System Settings ›
Keyboard › Keyboard Shortcuts › Screenshots) until the user turns them off. The established Mac
screenshot tools handle this the same way: Shottr's start guide asks the user to turn the system
shortcuts off first and links to System Settings; CleanShot X offers a "Use System Default
Shortcuts" button that assigns them in the app. Turning Apple's shortcuts off from code means
writing `com.apple.symbolichotkeys` and running the private `activateSettings` tool; that
changes another app's settings, is undocumented, and FR-01 forbids replacing Apple's shortcuts.
KeyboardShortcuts also warns against initial shortcuts that steal existing ones.
Carbon does not report the clash: on macOS 27.2, `RegisterEventHotKey` with
`kEventHotKeyExclusive` returns `noErr` for ⇧⌘4 while the macOS shortcut is enabled, so a
registration probe alone would call a default working when it is not.

## Decision

| macOS | Recortia default |
|---|---|
| ⇧⌘3 (save the whole screen) | Capture Display |
| ⇧⌘4 (save a selected area; Space for a window) | Capture Region; Space switches to Capture Window |
| ⇧⌘5 (screenshot options) | Capture Menu: every capture mode in a menu at the pointer |

- Recortia never changes the macOS shortcuts. A default is **held**, not registered, while an
  enabled macOS shortcut uses the same keys (read with Carbon's public `CopySymbolicHotKeys`, the
  check KeyboardShortcuts' recorder uses). Settings and onboarding say so and open System Settings
  › Keyboard. Once the user turns the macOS shortcut off, Recortia notices within two seconds (it
  checks only while something is held, and whenever it becomes active) and starts using it.
- A shortcut that fires while macOS also claims it does nothing, so a macOS shortcut turned back on
  later never makes both apps react.
- Defaults are written once per defaults version, on a normal launch, only to commands without a
  shortcut and only when no other Recortia command already uses that combination. A shortcut the
  user cleared stays cleared. Restore Defaults puts every command back to this table.
- ⌃⇧⌘3 and ⌃⇧⌘4 (copy straight to the clipboard) are not mapped: in Recortia every copy goes
  through the editor, where redaction happens, and automatic copy is an explicit setting.
- The E2E runner never seeds or registers shortcuts in the user's preferences; it works in its own
  `dev.mvneves.Recortia.E2E` domain, which it clears first, with a fake list of macOS shortcuts.

## Failure modes considered

1. Both apps react to one key press → held while macOS claims it, and a fire-time check.
2. The default stays silent after the user turns the macOS shortcut off → re-check every two
   seconds while held, and on activation.
3. Seeding overwrites a user's choice, revives a cleared one, or duplicates a combination that
   another Recortia command uses (two actions per press) → only unassigned commands, once, and
   never a combination in use.
4. Tests write the user's preferences or grab global keys → seeding runs only on normal launch;
   the harness never registers handlers.
5. Another app holds the combination → the registration probe reports it (existing message).
6. Space during a drag, in Capture Text, or a repeat region → ignored; only a plain region
   selection switches.
7. The menu shows ⇧⌘4 next to Capture Region while macOS owns it → hints only for active
   shortcuts.

## Consequences

- New installs work with ⇧⌘3/4/5 once the macOS shortcuts are off, and are told how.
- Upgrading from an earlier beta gives unassigned commands the defaults once.
- Regression tests: `ShortcutStatusModelTests`, `ShortcutDefaultsPlanTests`,
  `CaptureCoordinatorTests` (window switch), and the `shortcuts` and `capture` E2E scenarios.
