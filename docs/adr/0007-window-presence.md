# ADR-007: Recortia joins the window switchers while it has a window open

**Status:** Accepted (2026-10-07)

## Context

The owner reported that Recortia's windows do not appear when they press ⌥Tab. Measured on
2026-10-07 with the screen unlocked, AltTab 11.7.1 (the owner's ⌥Tab switcher) and macOS 27:

- AltTab listed a control window in all four combinations of activation policy (regular,
  accessory) and Space behavior (default, `SpacePolicy.followsActiveSpace`), and listed the
  installed 0.10.2 Settings window (`shown=True`). Ordinary windows were never the problem.
- AltTab listed **no** window for a pin-shaped panel (`NSPanel`, `.floating`, joins all Spaces).
  Its admission rule (`WindowAdmissionResolver`, tag v11.7.1) rejects the `AXFloatingWindow`
  subrole and admits a window above the normal level only when accessibility reports it as the
  app's single main window. Two normal-level test pins were both listed; two floating ones that
  could become main produced one entry (the main one), reported at 0×0.
- macOS ⌘Tab and the Dock never list an `LSUIElement` (accessory) app.

So a pin can float above other windows or be reachable from ⌥Tab, not both. The owner chose
reachability, and asked that Recortia also appear in ⌘Tab and the Dock while it shows a window.

## Decision

1. **Pins are ordinary windows.** A pin is a normal-level, borderless, movable window that still
   joins every Space. Other windows can cover it; ⌥Tab, ⌘Tab, the Dock and Bring Pins Forward
   bring it back.
2. **Activation follows window presence.** Recortia launches as an accessory app (`LSUIElement`
   stays `true`, so launch shows no Dock icon). It becomes a regular app while any switchable
   window exists: a top-level window at the normal or modal-panel level that is visible or
   minimized (editor, Settings, onboarding, scrolling review, About, alerts, pins). It returns to
   accessory when none remains. `AppPresence` owns the rule:
   - Presenting code activates through `AppPresence.activate()`, which becomes regular first:
     switching after activation leaves the previous app's menu in the menu bar. Code that orders
     a window without activating calls `AppPresence.windowWillAppear()`.
   - Demotion is coalesced to the next main-queue turn, so replacing one window with another
     does not flash the Dock icon.
   - While capture has temporarily hidden Recortia's windows, or the app is hidden (⌘H), the
     policy does not demote: those windows still exist for the user.
   - Clicking the Dock icon restores a minimized window before it falls back to Settings.
3. **Opening Recortia shows a window.** A menu-bar app is otherwise invisible after being opened:
   the owner opened 0.11.0 twice, saw nothing, and quit (unified log, 2026-10-07). A launch by
   the person shows onboarding or Settings; a launch whose open-application event carries
   `keyAELaunchedAsLogInItem` ("Open at login") shows none once onboarding is complete;
   unfinished onboarding takes precedence, as FR-01 requires. No source confirms that
   `SMAppService.mainApp` login launches carry the marker, so a missing marker shows Settings at
   login (visible) rather than hiding a window on a manual launch. Each launch logs its kind
   (subsystem `dev.mvneves.Recortia`, category `launch`), so a real login settles it.
   Automatic termination needs no change: an experiment showed it already off
   (`supportsAutomaticTermination=0`); `_kLSApplicationWouldBeTerminatedByTALKey` does not mean
   the app is eligible.
4. **Pins can be copied and dragged out**, adopted from Tendedero's click-to-copy and
   drag-to-share. The export reuses `ExportCoordinator` and the drag-out lease (ADR-004):
   - Only a pin rendered from a document session through the sanitizing renderer is exportable;
     an image added directly (previews, E2E fixtures) is refused.
   - Each pin has its own export identity. `ExportPipeline` encodes the pin's sanitized raster
     fresh with the allowlisted metadata; it remains the only constructor of `ShareSnapshot`.
   - Closing or invalidating a pin makes a pending export stale and revokes its drag offer.
   - The export is the pinned raster at its rendered size; zoom and opacity are display only.

## Alternatives rejected

- **Always a regular app.** Simplest code, but a Dock icon while nothing is open; Apple's
  guidance ties overlays above other apps' fullscreen Spaces to accessory apps.
- **A per-pin "Keep on top" toggle.** Keeps floating pins, but they stay out of ⌥Tab by default
  and every pin gains a control.
- **Inferring presence from `SpacePolicy` flags.** The flags describe Space behavior, not
  whether a window is somewhere the user can switch to.

## Consequences

- SPEC FR-01 and FR-09 change; UX-02 and PIN-02 cover the new behavior; PERF-02 records the
  window-open latency budget.
- The Space evidence in SOURCES S22 was measured with an accessory app. The probe gains a mode
  that switches to regular when its window appears, and the installed app is checked again
  over another app's fullscreen Space.
- Tendedero features not adopted, and why: taking over the macOS screenshot settings (Recortia
  never changes system settings), hiding during fullscreen with private window-server calls
  (no private frameworks), watching the Desktop or screenshot folder (implicit file reads),
  restoring the shelf after quit (no local screenshot archive), and system sounds (cut by the owner).

## Amendment (2026-11-21): the menu-bar icon can be hidden

**Context.** Some people use Recortia only through its global shortcuts and want no menu-bar
icon. The owner approved this as a class B change behind a setting whose default keeps the icon.

**Decision.**

- Settings › General › "Show the icon in the menu bar" is on by default; preferences written
  before it existed load as on. Off, the `MenuBarExtra` is not inserted (SwiftUI's `isInserted`).
  Removing the icon from the menu bar with ⌘-drag takes the same path as the switch.
- The way back is opening Recortia again. Finder, the Dock, Spotlight and `open -a` show Settings:
  `LaunchWindow` already chooses Settings for every launch by the person once onboarding is
  complete, and `handleReopen` shows it when no window is visible (a minimized one is restored
  first, as before). `LaunchWindow` moved into Features so a unit test guards that rule on hosted
  CI, which runs no E2E. "Open at login" stays silent. The global shortcuts keep working.
- The first time the icon is hidden, the standard message presenter says once how to get back;
  a preference records that it was said, so it is never repeated.
- Presence and quitting do not change: the accessory/regular rule above stands, and with "Keep
  running in the menu bar" on, closing the last window keeps the process running without an icon.

**Alternatives rejected.**

- **Become a regular app while the icon is hidden**, so the Dock icon is the way back. It replaces
  one always-visible icon with another and breaks the accessory rule this ADR relies on for
  overlays above other apps' fullscreen Spaces.
- **Turn "Keep running in the menu bar" off with the icon**, so closing the last window quits. It
  silently changes a separate preference, and the shortcuts would stop working after every close.
- **Show Settings at every login while the icon is hidden.** It defeats the reason for hiding it.

**Consequences.** The `settings` and `launch-presentation` E2E scenarios cover the switch, the
single message and reopening with the icon hidden. Whether the status item really leaves and
returns, and a relaunch from Finder or Spotlight, remain physical checks.

## Amendment (2026-11-21): Keep on Top and click-through, per pin

**Context.** Pins as normal-level windows (decision 1) cannot stay above the window a person is
working in, which is what a reference pin is often for. The rejected alternative above, a per-pin
"Keep on top" toggle, was rejected as a default; the owner approved it as an opt-in (program
2026-11, T3 B-3), together with click-through for tracing over or reading through a pin.

**Decision.**

- **Keep on Top**, per pin, off for every new pin. On, the pin floats above normal windows
  (`.floating`) and keeps `SpacePolicy.joinsAllSpaces`; off, it is the normal-level window of
  decision 1. The default pin is unchanged.
- **Click-through**, per pin, off for every new pin, and only available while the pin is on top:
  a click-through pin at the normal level would sink under the window the click reaches, leaving
  nothing to see or click. Turning Keep on Top off also ends click-through. On, the pin ignores
  mouse events and shows a lock in its corner, so a locked pin never looks like an ordinary one.
- Both toggles are in the pin's hover control strip and its context menu. A click-through pin
  cannot be clicked to reach either, so **Unlock All Pins** (Window menu, and the menu-bar extra's
  Pins submenu) turns click-through off on every pin and keeps their level. It is enabled only
  while a pin is click-through. With the menu-bar icon hidden, a pin still makes Recortia regular,
  so ⌘Tab or the Dock reaches the app menu; Close All Pins remains in both menus as before.
- **Presence.** A pin is a switchable window at any level: `AppPresence.isSwitchable` counts a
  `PinPanel` even when it floats, so the app stays regular, the Dock click and the last-window rule
  treat it like any other pin.
- Exports do not change: copy and drag-out still export the pin's sanitized raster through
  `ExportPipeline`.

**Accepted cost.** A third-party window switcher may no longer list a pin while it floats; the
measurement in Context showed floating windows are rejected. Turning Keep on Top off brings it
back, and ⌘Tab and the Dock still reach Recortia.

**Alternatives rejected.**

- **Click-through on its own, at any level.** Simpler rule, but a click-through normal-level pin
  disappears behind the first window clicked through it.
- **A modifier-key unlock** (holding a key restores clicks). It means watching the keyboard while
  any pin is locked, and the held key also reaches the app the person is working in.

**Consequences.** The `pin-on-top` E2E scenario drives both toggles through the real strip and
checks the window level, `ignoresMouseEvents`, the lock, the Space behavior, Unlock All Pins on
every pin and in the menu bar, and (in a child-process probe) that a shown floating,
click-through pin keeps Recortia regular. Whether a third-party switcher lists a floating pin, and
clicks really passing through to another app, remain physical checks.
