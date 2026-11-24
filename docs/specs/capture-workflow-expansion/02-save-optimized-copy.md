# 02. Save an optimized copy

See the [optimized save specification](optimized-save-spec.md) for overwrite consent, dialog
cancellation and the file sink's commit boundary.

**Status** focused verification passed. The bilingual native thumbnail scenario uses scripted
destination and replacement decisions. The system Save panel and replacement focus remain
manual checks. See [progress](../../../progress.md).

**Blocked by** 01, to share the verified thumbnail lifecycle and native control surface.

**What to build** From the thumbnail, prepare and save an optimized PNG or JPEG while showing the actual format and file size.

- [ ] Reuse the existing automatic PNG/JPEG encoder and sanitized export snapshot.
- [ ] The destination prompt shows the encoded format and size. Confirm the actual destination even when a preferred folder is set.
- [ ] The approved file contains the same bytes as the prepared export. Replacement consent is scoped to the exact destination.
- [ ] Cancellation, a stale capture or failed delivery never overwrites an existing file. The original capture remains usable if still held.
- [ ] Verify native Save behavior, byte/metadata checks and RED controls in both languages.
