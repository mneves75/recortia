# ADR-010: Region selections snap to interface elements, read as frames only

**Status:** Accepted (2026-11-21) by the coordinator at the plan's scheduled ADR stop, under the
owner's 2026-11-20 delegation (`docs/specs/program-2026-11/decisions.md`); the owner may overrule it
before the release that ships it.
**Requirements:** FR-02 · Program 2026-11 B-7 · **Verification:** `ElementSnappingTests`,
`ElementSnappingCaptureTests`, bilingual E2E `element-snapping` and `settings`

## Context

A-4 snaps a dragged selection edge to the display's edges and to other apps' window frames, which
come from the window list Recortia already reads for the window chooser. Edges inside a window (a
sidebar, a toolbar, a button) are not in that list. Two sources have them: the pixels on screen, or
the other app's Accessibility tree.

Today Recortia holds Accessibility only for automatic scrolling (ADR-002). Reading another app's
element tree is a new use of that grant. The tree also carries on-screen text: element values,
titles, descriptions, selected text. Through it Recortia could read what is on screen without a
capture the person started. So this decision has to say what is read, for how long, and what
stops it from growing.

## Decision

1. **Opt-in.** Settings › Capture has "Snap to interface elements", off by default, stored as the
   optional `snapsToInterfaceElementsChoice`, so older preference blobs decode.
   - Turning it on is the only new place that asks for Accessibility. It asks through the path
     automatic scrolling already uses (`AccessibilityPermissionService.requestWithPrompt`), and
     both options share one status row.
   - A capture never prompts. `InterfaceElementFrameService` has no request method, and the live
     service only checks `AXIsProcessTrusted`.
   - Without the grant the option stays on and has no effect.
2. **Frames only.** For each element Recortia reads AXPosition, AXSize and AXRole, plus AXChildren
   to walk the tree, and nothing else.
   - `InterfaceElementReading` holds a frame and a two-case kind (container or element), so no
     text can travel through it. A test checks that shape.
   - `LiveInterfaceElements.swift` spells the attribute names as literals so a reader can audit
     them.
   - Recortia never reads AXValue, AXTitle, AXDescription, AXHelp, AXSelectedText or any
     parameterized text attribute.
3. **Which app.** When a region selection starts with the option on, Recortia finds the frontmost
   on-screen window under the pointer (CGWindowList order, its own windows excluded). It reads
   that window's app only when the window is in the list A-4 loaded (layer 0, another app),
   through `AXUIElementCreateApplication(ownerPID)`.
4. **Bounded.** `ElementSnapping.walk` goes breadth first, so when a bound cuts the walk short the
   larger, shallower elements are the ones kept.
   - Depth: at most 12 levels below the application.
   - Count: at most 2,000 elements taken in; children are requested with the room that is left.
   - Time: a 150 ms deadline, checked before every message, and a 50 ms messaging timeout on every
     element reference, so the walk ends at most one message after the deadline.
   - It runs in a `@concurrent` function, off the main actor.
5. **Filtered.** The application and its windows are walked but not kept, because the window list
   already gives window frames. Elements smaller than 8 pt on either side, non-finite frames,
   frames that touch no display and duplicates are dropped. What remains joins the window frames
   as extra snap frames in `RegionPrecision.guides`, and Command still turns snapping off.
6. **One selection.** `CaptureCoordinator` accepts a result only while the same capture request
   is still selecting a region (request ID, state and mode).
   - Escape, commit, Space to a window selection, a replacing capture and a display change drop
     the read in progress and the frames.
   - The frames are never logged, persisted or exported.
   - E2E reports carry element counts, never frames.
7. **Fails open to A-4.** No grant, no listed window under the pointer, an unreadable app, a
   timeout or a failed window list each leave display snapping working. Window snapping keeps
   working too whenever the window list loaded.

## Alternatives

- **Edge detection on the captured pixels**, the editor-time approach a reference product takes.
  It needs no new permission. But during a live selection Recortia holds no image of the screen
  (a frozen frame is A-5, not built), it costs image work per selection, and content edges
  (photos, text, gradients) become false targets. Rejected for live selection; it could
  complement this after A-5.
- **Window frames only (A-4 as shipped).** No new permission, but no edge inside a window. It
  stays the default and the fallback.
- **Accessibility with text attributes**, for example titles to label guides or text runs for
  finer edges. Rejected: it reads on-screen text through Accessibility, outside both the
  Screen Recording consent and the frames-only promise above.

## Consequences

- **A shared TCC grant.** Automatic scrolling and element snapping share one Accessibility grant,
  and each is still gated by its own setting. Granting it for one makes the other available.
  Revoking it turns both off.
- **The limit is Recortia's code.** The grant itself lets the process read text. The frames-only
  limit is enforced by Recortia's code and its tests, not by macOS, the same unsandboxed caveat
  ADR-002 records.
- **Docs updated.** ADR-002's permission bullet, Settings › Privacy and THREAT_MODEL.md name the
  second use. SPEC.md's permission row and README's privacy paragraph still say "automatic
  scrolling only". Those are owner text, updated when B-7 is approved and published.
- **Qualification gaps.** `element-snapping` uses a synthetic element source, and no gate reads a
  real Accessibility tree or touches TCC. Not yet qualified:
  - trees of real apps (AppKit, SwiftUI, Safari, Chromium/Electron, Java);
  - walk time on large trees;
  - behaviour with a hung app;
  - negative-origin multi-display coordinates on hardware;
  - the live prompt flow.
- **Known limitation.** Elements are not clipped to what is visible. A row scrolled out of its
  view, or an element covered by another window, can still produce a guide. Clipping each element
  to its ancestors' frames is the likely fix and needs real-app evidence first.
