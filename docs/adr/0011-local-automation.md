# ADR-011: Local automation, part 1: capture intents behind the system's confirmation

**Status:** Proposed (2026-11-21) by the coordinator for the plan's scheduled ADR stop, under the
owner's 2026-11-20 delegation (`docs/specs/program-2026-11/decisions.md`). Three fresh-context
adversarial reviews rejected earlier drafts; the ledger below records what each found and what was
done. It is accepted only if the final review finds no path to a forbidden outcome (Threat model);
the owner may overrule it, including the deferrals, before the release that ships it.
**Requirements:** FR-16 (automation; writing assistance stays unapproved), SPEC §13 "Optional local
automation" · Program 2026-11 B-2 (part 1) · **Verification:** `AutomationCaptureTests`,
`AutomationIntentTests`, bilingual E2E `automation`

## Context

The owner approved FR-16 automation on 2026-11-19, to be built only after this ADR. SPEC §13: "An
integration may open the app or initiate a user-visible workflow; an untrusted deep link must not
silently capture, save, upload, or overwrite the clipboard. Strictly allowlist actions/parameters
and require confirmation at the side-effect boundary. Do not ship an arbitrary scripting or
tool-execution engine."

App Intents run from Shortcuts, Spotlight or Siri, and as unattended Shortcuts automations (a time
of day, a Focus change) while the person is doing something else. A shortcut can be written by
someone else and installed by the person.

Current capture behaviour that matters here: the region overlay is a nonactivating panel that
takes keyboard focus and accepts the first mouse click, and Return with no selection captures the
whole display (`RegionOverlay.swift`); the window chooser activates the app, preselects its first
row and binds Return to Capture (`ChooserViews.swift`); a finished capture runs the person's
automatic export plan (copy, save to a folder, GitHub upload) through the editor or the
quick-action thumbnail (`AppModel.runAutomaticExports`).

## Threat model

- **Adversary.** A shortcut the person installed, possibly written by someone else, running
  unattended at a moment the person did not choose. It can invoke Recortia's intents in any order
  and repeatedly. It cannot inject input into Recortia or read Recortia's memory.
- **Forbidden outcomes.** (F1) screen pixels or recognized text leave Recortia: clipboard, a file,
  an upload, a drag, a return value to the shortcut; (F2) an existing file is overwritten; (F3) a
  capture starts without the person answering a confirmation that names it; (F4) an automation
  path changes a setting or a permission.
- **Accepted residual.** After the person confirms in the system's prompt, the capture UI (overlay
  or chooser) appears, and an editor window can open with the result. A stray click or drag at
  that point can produce an unwanted editor window. It stays on this Mac, in memory, visible and
  dismissible; closing it discards it, and nothing leaves Recortia unless the person then exports
  by hand. This is the "user-visible workflow" SPEC §13 allows. A cold launch by the system can
  also show the ordinary launch window (onboarding or Settings), which moves no data.

## Decision

1. **Four intents, nothing else.** `CaptureRegionIntent`, `CaptureWindowIntent`,
   `CaptureTextIntent` and `OpenRecortiaIntent`, in the main app target only (not the E2E app).
   They take no parameters, return no value, and call one main-actor `AutomationRouter`, the only
   way automation reaches the app. No URL scheme and no file intents in this part (see
   Deferred).

2. **The system asks first (F3).** A capture intent's `perform()` first awaits the system
   confirmation, `requestConfirmation(conditions: [], actionName: .continue, dialog:)` with
   "Capture a region of the screen with Recortia?" (window, text). The prompt is drawn by the
   system host (Shortcuts, Spotlight), not by Recortia, so no Recortia window appears before the
   answer. Declined, cancelled, thrown or unanswered: `perform()` ends as cancelled having shown
   nothing and started nothing. Nothing in Recortia is reserved before that call returns. The
   builder verifies, from Apple's documentation or the SDK, that empty conditions mean "always
   confirm"; if not, the intent passes the conditions that do.

3. **Admission is one main-actor step.** After confirmation, the router checks `isEnabled`, that
   no still capture, scrolling capture or scrolling startup (`isStartingScrollingCapture`) is
   active, that the session is unlocked and active, and that the intent task is not cancelled; if
   all hold it starts the capture in that same step with an automation origin and the capture's
   request ID. Otherwise it returns refused. A lock or session change after start interrupts the
   capture as today.

4. **An automation capture keeps everything inside Recortia (F1, F2).** The origin travels with
   the capture request to completion.
   - It never runs the automatic export plan, whatever Settings say, and always opens in the
     editor, never the quick-action thumbnail. The editor's masking gate applies unchanged.
     Capture Text opens the editor with recognition, as the menu does; copying the text is the
     person's action.
   - It changes no preference and requests no permission beyond the Screen Recording check every
     capture already makes (F4).

5. **The capture surface needs fresh input.** For an automation capture:
   - The region overlay and the chooser ignore a mouse or key event whose timestamp is earlier
     than the moment the surface appeared, so input already in flight cannot start or commit a
     selection.
   - Region and text: Return with no selection does nothing; the person drags a region.
   - Window: the chooser opens with no row selected and no default button; Return does nothing
     until the person picks a window, and a pick commits only through Capture. A region overlay
     that switches to window selection with Space follows the same rule.
   - `commitSelection` checks the request ID, the current selection stage and the target kind
     together; a region callback that arrives after a switch to window selection for the same
     request is refused.

6. **Typed outcomes, no content (F1).** The router returns started, cancelled or refused. A
   capture intent succeeds when the capture has started; a later permission denial or cancelled
   selection is handled inside Recortia as today. Cancelled and refused reach the shortcut as
   content-free errors. No intent returns pixels, text, a file or a link.

7. **Open Recortia** is a foreground action with no confirmation: it shows Settings, after the
   same busy check, exactly as opening the app does. It moves no data.

8. **Execution and discovery.** `openAppWhenRun` is not used (deprecated in macOS 26). The intents
   run in the app process; the builder records the `supportedModes` value the installed SDK needs
   so the system confirmation is shown and the app is not brought forward before it. Intent titles
   and descriptions are localized (EN, pt-BR). An `AppShortcutsProvider` may be added, but phrase
   discovery on macOS is claimed only with installed-app evidence. Intent type names are a public
   contract from the release that ships them.

## Deferred (entry conditions for a later ADR)

- **A `recortia:` URL scheme.** Any process or web page can open one. It needs: exact-string
  matching (Foundation decodes `%63apture` to `capture`); no activation, focus change or Recortia
  window before deliberate interaction with Recortia; an expiring pending request; cold-launch
  suppression of the launch window before `LaunchWindow.choose`; ordering against separate
  file-open callbacks; registration in the production target only (both targets share plist
  settings).
- **Open Image and Pin Image intents.** They need: data-only and dataless (cloud placeholder)
  inputs refused without materializing them; security scope held across the awaited read; a
  non-presenting import result; Pin only after masking settles on that exact session and the
  person reviews the image and presses Pin; cancellation that fences late results.

## Alternatives

- **Recortia's own confirmation panel** (drafts 2 and 3). Rejected: an unsolicited panel can take
  a click meant for another app, and a key panel can take its keystrokes; the system prompt in the
  intent host has neither problem.
- **Trust intents without asking** (draft 1). Rejected: unattended automations, the chooser's
  preselection and the overlay's Return fallback made a keystroke into a capture.
- **Keep automatic exports for automation captures.** Rejected (F1): the confirmation names a
  capture, not a copy, save or upload.
- **Return recognized text or the image to Shortcuts.** Rejected for now (F1); it needs its own
  decision with masking and consent rules.

## Review ledger

| Round | Finding | Outcome |
|---|---|---|
| 1 | Intent run is not consent; chooser Return | Fixed: system confirmation (2), fresh-input and chooser rules (5) |
| 1 | Automatic exports after an approved capture | Fixed: origin suppresses the plan (4) |
| 1 | Confirmation/capture race, cold launch, activation | Fixed for intents (2, 3); URL parts deferred |
| 1 | URL parsing representation | Deferred with the URL scheme |
| 1 | No pin command, file lifetime, pin masking | Deferred with the file intents |
| 1 | E2E bypassing the shipping route; discovery claims | Fixed: shared router, production-only metadata (Consequences, 8) |
| 2 | Whole-display Return fallback | Fixed (5) |
| 2 | Foreground and cold-launch policy | Fixed: no Recortia UI before the system prompt (2); cold launch window is accepted residual |
| 2 | Async file work, URL ordering, file materialization, pin handoff | Deferred with the URL scheme and file intents |
| 3 | Unsolicited panel takes an unrelated click and drag | Fixed: Recortia's panel removed (2); in-flight input ignored (5); a stray drag after confirming is accepted residual |
| 3 | Selection stage not bound at commit | Fixed (5) |
| 3 | Approval survives caller cancellation or lock | Fixed: nothing reserved before confirmation returns; admission checks cancellation and session (3) |
| 3 | Foreground and cold launch left to the builder | Fixed (2, 8); cold launch window is accepted residual |

## Consequences

- **No new entitlement, no URL registration.** App Intents metadata is generated at build time
  for the production target only. The signed Release entitlement set is unchanged and stays
  checked by the existing gate.
- **Testing.** `AutomationIntentTests`: a declined, cancelled or throwing confirmation starts
  nothing; admission refuses while busy, starting a scroll, locked or cancelled.
  `AutomationCaptureTests`: no automatic export with every export preference on, for both
  after-capture settings; in-flight input ignored; Return without a selection does nothing; no
  chooser preselection; `commitSelection` refuses a stale stage. The bilingual E2E `automation`
  scenario drives the shipping router through the calls the intents make, with synthetic sinks, a
  positive control that proves the sinks see an approved capture, and zero captures, clipboard
  writes, saves and uploads on every refused and cancelled path.
- **Not testable here.** The system confirmation in Shortcuts, Spotlight and Siri, unattended
  automations, cold launch by the system and fullscreen behaviour need the owner on the installed
  app. They are recorded as `awaiting_manual_validation`, not passed.
- **Later.** The URL scheme, file intents, returned results or more actions each need a change to
  this ADR.
