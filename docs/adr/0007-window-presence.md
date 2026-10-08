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
   `keyAELaunchedAsLogInItem` ("Open at login") shows none. No source confirms that
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
