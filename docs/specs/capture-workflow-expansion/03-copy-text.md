# 03. Copy recognized text

**Status** implemented. The native bilingual scenario compiles and awaits execution.

**Blocked by** 01, to share the verified thumbnail lifecycle and native control surface.

**What to build** Offer **Copy Text** for the current capture using on-device recognition over the sanitized revision.

Use the editor's recognition language selection and text formatting. Render the current secure
document at normal output resolution so the quick preview's downsampling does not limit OCR.
Keep the thumbnail available after copying text so the person can still save or copy the image.
The shared inactivity countdown resumes when the recognition action ends.

Use the thumbnail's existing action slot. Hold its capture identity across rendering, language
selection and recognition. Starting another capture selection cancels pending recognition, even
when cancelling that selection would restore the original thumbnail. Recheck identity immediately
before the synchronous clipboard write. Preserve the current clipboard on empty results, render
refusal, stale results and cancellation.

Successful recognition uses macOS's standard plain-text replacement. The app reports a failure
to publish, and never reads or retains prior clipboard contents to attempt a rollback.

- [ ] Publish correctly ordered local text only after the explicit action and successful recognition of the still-current capture.
- [ ] Empty or cancelled results, privacy refusal and stale callbacks leave the clipboard unchanged.
- [ ] Masked pixels cannot reach recognition. The action creates no saved text, new capture or external transfer.
- [ ] Verify the native action label and outcome in English and Brazilian Portuguese, including accents and failed/cancelled cases.
