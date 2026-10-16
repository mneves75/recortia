# ADR-004: Drag-out offers are revocable until the receiver writes the file

**Status:** Accepted (2026-09-26)

## Context

SPEC.md §7.3 asks that "drag receivers get a complete file for the transfer lifetime" and that
cancellation after a commit report that the action already completed. A drag-out cannot commit when
the user presses Drag Out: AppKit can only start a drag inside a mouse event, so Recortia offers the
sanitized snapshot on a small chip, and the receiving app asks for the promised file later, on
another thread, after the drag session has ended — or never.

During that unbounded wait the user can keep editing. The security audit (run-1) and an
independent review showed that an offer made before a new secure redaction could still deliver the
older pixels, and that a promise handed to one receiver could outlive the chip.

## Decision

Every drag-out offer carries an `ExportLease` (Domain) with four states:
`active → committing → committed`, or `active → revoked`.

- The promised-file write runs only if it can claim the lease (`active → committing`); the lock is
  held only to claim and settle, never during disk I/O. A write that succeeds commits the lease;
  a failed write returns it to `active` (or `revoked`, if a revoke arrived meanwhile).
- The lease is revoked when the document changes (any edit, redaction, undo, or redo), when the
  user cancels the export, when the editor closes, and whenever the offer ends for any other reason
  (the chip is closed, or the drag is reported delivered). Revoking a committed lease does nothing.
- The coordinator reports the outcome from the lease, not from the chip: a committed lease is a
  delivered export (or "already completed" if a cancel came later); a revoked one is stale; an offer
  that ended without a write is canceled.
- Each chip offer has its own identifier (`PendingOffer`), so a late write completion from an earlier
  chip can never resolve a newer one.

## Consequences

- A receiver that asks for the file after the user edited, canceled, or closed the editor gets
  nothing (the promise fails), instead of pixels older than a newer redaction. This departs from
  "a complete file for the transfer lifetime" only for offers the user has already superseded.
- A committed export is never reported as canceled or stale (SPEC.md §7.3, EXP tests).
- One offer delivers one file: dropping the same chip on a second receiver after the first write
  gets nothing. Drag Out again to export again.
- Regression tests: `ExportLeaseTests`, `DragOutProviderTests`, `PendingOfferTests`, and the drag
  cases in `ExportCoordinatorTests` and `EditorExportTests`.
