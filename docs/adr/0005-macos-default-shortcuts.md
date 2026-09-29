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

Carbon does not report either kind of clash. Measured on macOS 27.2: `RegisterEventHotKey` with
`kEventHotKeyExclusive` returns `noErr` for ⇧⌘4 while the macOS shortcut is enabled, and also
while another app holds the same keys with an ordinary (non-exclusive) registration, which is how
KeyboardShortcuts and most apps register. Only another app's exclusive registration fails the
probe. `CopySymbolicHotKeys` is the public way to see the enabled macOS shortcuts; HIToolbox
implements it with the window server's `CGSGetSymbolicHotKeyValuesAndStates`, so it reflects
changes without a relaunch.

## Decision

| macOS | Recortia default |
|---|---|
| ⇧⌘3 (save the whole screen) | Capture Display |
| ⇧⌘4 (save a selected area; Space for a window) | Capture Region; Space switches to Capture Window |
| ⇧⌘5 (screenshot options) | Show Capture Menu: every capture mode in a menu at the pointer |

- Recortia never changes the macOS shortcuts. A default is **held**, not registered, while an
  enabled macOS shortcut uses the same keys. If macOS cannot list its shortcuts, every shortcut
  counts as taken (fail closed). Settings and onboarding say so and open System Settings ›
  Keyboard. Holding a shortcut, by any path, starts a check every two seconds that stops when
  nothing is held, and Recortia also re-checks when it becomes active; once the user turns the
  macOS shortcut off, Recortia starts using it.
- A shortcut that fires while macOS also claims it does nothing, so a macOS shortcut turned back on
  later never makes both apps react.
- Changing one assignment or restoring defaults first unregisters all Recortia shortcuts, then
  writes the new assignment and checks which combinations macOS still owns before registering.
  This also covers the shortcut recorder's synchronous write path.
- Defaults are assigned on a new install only (onboarding not completed), each default once
  (recorded by name, so a later version's new default is offered once and a cleared one never
  returns), only to commands without a shortcut, and never onto keys another Recortia command
  uses. Someone upgrading may have given these keys to another app: their defaults are recorded as
  offered and applied only through Restore Defaults, which puts every command back to this table.
- Another app's ordinary registration of the same keys cannot be detected; onboarding asks users
  of another screenshot app to clear the defaults it already uses.
- Not mirrored: ⌃⇧⌘3 and ⌃⇧⌘4 (copy straight to the clipboard), because every Recortia copy goes
  through the editor where redaction happens and automatic copy is an explicit setting; Space back
  from the window chooser to a region, and Shift, Option, or Space adjusting a selection while
  dragging, which change the overlay rather than the shortcuts.
- The E2E runner never touches the app's preferences domain or the host's keys: it works in its own
  `dev.mvneves.Recortia.E2E` domain, cleared first, with a fake list of macOS shortcuts and a probe
  that never calls Carbon, and it installs no shortcut handler.

## Failure modes considered

1. Both apps react to one key press → held while macOS claims it, a fire-time check, and fail
   closed when macOS cannot list its shortcuts.
2. The default stays silent after the user turns the macOS shortcut off → every hold starts the
   two-second watch; activation also re-checks.
3. Seeding overwrites a user's choice, revives a cleared one, duplicates keys another Recortia
   command uses, or takes keys an upgrading user gave to another app → only new installs, only
   unassigned commands, each default once, never keys in use.
4. Tests write the app's preferences or grab the host's keys → isolated domain, fake macOS list,
   Carbon-free probe, no handlers.
5. Another app holds the keys → detected only for exclusive registrations; otherwise stated in
   onboarding and Settings.
6. Space during a drag, in Capture Text, or in a scrolling selection → ignored; only a plain region
   selection switches.
7. The menu shows ⇧⌘4 next to Capture Region while macOS owns it → hints only for active
   shortcuts.

## Consequences

- New installs work with ⇧⌘3/4/5 once the macOS shortcuts are off, and are told how.
- Upgrading keeps every existing assignment; Restore Defaults opts in.
- Shortcut assignments stay in KeyboardShortcuts' preferences, outside the sealed Recortia
  preferences (see THREAT_MODEL.md residuals).
- Regression tests: `ShortcutStatusModelTests` (states, holding, seeding and restore plans),
  `CaptureCoordinatorTests` (window switch), and the `shortcuts`, `capture-menu`, and
  `space-window` E2E scenarios.
