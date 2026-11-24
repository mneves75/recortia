# Save an optimized capture copy

**Status** Detailed follow-up for ticket 02. Integrate after the quick capture preview is qualified.

## Problem statement

The user who wants a smaller saved copy from the quick-action thumbnail can change the default format or open the editor. Neither path offers the actual format and byte count before choosing where to save this one copy.

## Solution

**Save Optimized Copy…** produces a sanitized PNG or JPEG using the existing automatic encoder. The user sees the actual type, dimensions and byte count in the destination panel. The panel uses the corresponding filename extension. After destination approval, the same encoded bytes are saved through Recortia’s existing file sink.

1. A user can save this copy even when their default format is fixed or a preferred folder already exists. The default settings remain intact.
2. A user can cancel the save or decline replacement and keep the prior file and the current capture.
3. A user changing or replacing a capture during the dialog cannot accidentally save the previous capture after returning to the panel.
4. A user working with a transparent image retains alpha whenever the existing automatic rule selects PNG. If that rule selects JPEG, the existing opaque matte and quality apply.
5. A user who approves a file can verify that its extension, actual encoded bytes and on-disk size match what the dialog displayed.

## Implementation decisions

- Route the action through the existing `QuickActionsModel` capture identity and `ExportCoordinator` operation. Take one revision and privacy epoch, produce one `ShareSnapshot`, and retain that snapshot only for the current operation. The window controller receives format, size, byte count and the suggested filename. It never needs to read or render the source.
- Admit one export through the existing slot first. When the encoder completes, recheck cancellation and the current capture before showing a dialog. Register one cancellable dialog presenter with the owning operation. Replacement or dismissal closes any outstanding destination or confirmation dialog and frees the slot when the presenter unwinds, without waiting for a user response. When either dialog returns, recheck the same capture identity and operation before delivering. A stale or dismissed capture cannot start the file sink.
- Always use an explicit destination dialog for this action. The selected format is final before the dialog. Show the existing preferred folder only as an initial location where available. Scope overwrite consent to the normalized file URL that the sink would replace. Keep the existing file sink’s collision, safe-replacement and atomic-write checks.
- Keep a name collision recoverable within the same operation and keep the same bytes through replacement confirmation. Regular Save can currently retry with another render after a collision. For the optimized copy, a repeat render could give the already confirmed metadata a different meaning. Recheck liveness before every sink call. Cancellation before dispatch to the file sink writes nothing. After dispatch, existing noncancelable filesystem work can finish. A successful write reports `alreadyCompleted` after a late cancellation. A failure keeps the sink’s typed result, including any named leftover on volumes that require direct-create verification.
- Keep cancellation, a render failure and a permissions failure distinct from success. On failure, show the existing editor wording and keep the thumbnail if its capture is still held. Allow a successful save to retire it like regular Save. Use the same inactivity hold and release behavior as the existing save operation.
- This is the only route proposed here for a one-off optimized file. Existing PNG clipboard copy, Save, automatic exports, GitHub upload and document export defaults have no behavior change in this slice.

## Testing decisions

- Observe the highest existing seam from the quick-action control through snapshot generation and the file sink. Compare a digest of the confirmed snapshot bytes with the saved file. Force two different automatic selections with a photo and a transparent graphic; inspect the actual codec, dimensions, size, flattened pixels, alpha and metadata.
- Exercise a preferred folder, an existing PNG/JPEG name, cancelled destination, cancelled overwrite, a changed destination path, concurrent action refusal, and a sink error. Recheck that each refused route leaves the original file byte-identical. Replace the capture with each dialog unanswered and confirm the next capture’s automatic batch can finish. Hold an admitted sink call across a late cancellation and check its actual result. Verify that retry after declined replacement requests consent again and does not retain the old operation.
- Extend the existing RED and native quick-action flows using synthetic fixtures. Match both languages for action and status wording. Measure new production targets with `cccc` and avoid isolated tests for scores at or below 5 unless regular expressions are involved. Run the unsigned gate and qualify the destination panel on the dedicated desktop.

## Out of scope

Target-size search, a quality-slider preview, batch processing, clipboard format changes, background save, any new codec, and network sharing.
