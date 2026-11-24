# ADR-009: An optional quick-action thumbnail holds a capture only until it is dismissed

**Status:** Accepted (2026-11-20)

## Context

Every capture opens the editor (FR-01, FR-04). Most captures end in one action, so the enhancement
plan (B-1, `docs/specs/enhancement-plan-2026-11/plan.md`) proposed a small thumbnail with that
action one click or one drag away. It changes the capture-completion contract, and it creates a
new place where a capture's pixels can wait for the person: how long they wait there, and what
leaves the app from there, are privacy decisions. The owner decided them for T2
(`docs/specs/program-2026-11/plan.md`): an opt-in setting whose default keeps opening the editor,
a capture discarded when its thumbnail is dismissed, and automatic exports that run before it
shows.

## Decision

1. **Setting.** Settings › Capture › "After a capture": *Open the editor* (default) or *Show quick
   actions*. It is stored as the optional `afterCaptureChoice`, so preferences written before it
   load as *Open the editor*, and grants no side effect.
2. **Decided at capture.** `CaptureFollowUp.decide` runs synchronously in
   `AppModel.handleCapture`, beside `automaticExportPlan()`, so a Settings change queued after the
   capture applies to the next one. Capture Text, scrolling capture, import, paste and Open With
   keep their flows.
3. **Automatic masking wins.** With automatic masking on, a capture opens in the editor whatever
   this setting says. Nothing may show or export a capture before its masks land, and a failed
   masking must leave the person in the editor to review it (FR-06 amendment); the editor already
   does both. The setting's help says so.
4. **Automatic exports first.** The capture's automatic batch runs before the thumbnail shows,
   with the same plan and consent identity as the editor's batch, and waits for another export
   to free the shared slot as the editor does. With no editor notice slot, each failure is an
   alert.
5. **The panel.** A `HostingPanel` that does not activate Recortia, becomes key only when clicked,
   floats and joins all Spaces (`SpacePolicy.joinsAllSpaces`). Its floating level keeps it out of
   `AppPresence.isSwitchable`, so it never puts Recortia in ⌘Tab or the Dock. It appears in the
   lower-right corner of the pointer's screen and shows the sanitizing renderer's output scaled
   to at most 640 px, never stored pixels, as a pin does.
6. **Actions.** Each goes through `QuickActionsModel`:
   - Copy: `ExportCoordinator`, PNG.
   - Save: the folder chosen in Settings when it resolves (collision-free name); otherwise the
     editor's save panel, app-modal, and a confirmation before replacing a file (FR-07).
   - Drag: dragging the preview starts the existing drag-out export, whose sanitized snapshot is
     offered on the drag chip at the pointer under the ADR-004 lease.
   - Pin: `PinsModel`'s sanitized render.
   - Open in Editor: hands the session to an ordinary editor (SpacePolicy, AppPresence).
   - Dismiss: also Escape.
   - Copy Link, only when this capture's own automatic upload returned a link (its batch ran
     under the consent identity fixed at capture): writes the link as plain text through the
     editor's text clipboard. It exports nothing of the capture, so it does not end the
     thumbnail.

   A copy, save, delivered drag or pin ends the thumbnail. One that wrote nothing keeps it,
   shows the editor's wording for the failure and restarts the timer.
7. **Lifetime.** One capture at a time; a new capture replaces the thumbnail. The capture lives
   only in `ImageStore` (plus the sanitized preview). Its pixels are released when it is
   dismissed, when 8 s pass with no action and the pointer not over it (the pointer stops the
   timer; leaving starts the full 8 s again; an action in progress stops it too), after an
   action ends it, or when the next capture replaces it. Open in Editor transfers the pixels to
   the editor. A pin keeps only its own sanitized raster, as every pin does, so pinning also
   releases the capture. Ending the thumbnail cancels its running export, and any export still
   in flight finds no current session, so it writes nothing.

## Consequences

- Nothing is kept until quit. Quitting with a thumbnail shown discards it without asking: it
  holds no edits.
- Automatic GitHub upload runs before the thumbnail shows; its link is offered as Copy Link on
  that capture's thumbnail only, and its failures are alerts.
- Dragging is two motions, press-drag on the preview then drag the chip, because AppKit starts a
  drag only inside a mouse event and the snapshot is rendered first (ADR-004).
- A thumbnail on screen is ordered out with the app's other windows during the next capture
  (`CaptureWindowVisibility`), so it never appears in that capture, and is then replaced.
- Tests: `QuickActionsModelTests` (choice, masking fallback, batch before showing, release on
  dismiss, timeout, replacement and after each action, nothing written after dismissal) and the
  bilingual `quick-actions` E2E scenario (default, panel policy, Copy to the harness clipboard,
  Dismiss and Open in Editor against the image store's size, light and dark chrome). The
  `settings` scenario checks the control and its default. Hover and real drag-and-drop need a
  physical pointer and are not covered by synthetic E2E.

## Alternatives rejected

- **Keep a dismissed capture until quit** (a recent-captures shelf to reopen it). It would hold
  the raw pixels of every capture the person chose to discard for the whole session. The owner
  chose discard on dismiss; a shelf would be its own decision, with its own limit and clearing
  rules.
- **A locked thumbnail while masking runs**, showing a placeholder until the masks land. It
  duplicates the editor's pending and fail-closed states in a second surface for no gain: a
  failed masking needs the editor anyway.
- **A file-promise drag straight from the preview**, rendering the snapshot when the receiver
  asks for the file. It is a second drag path whose write happens after the drag began, so the
  ADR-004 lease rules would need proving again for it.
