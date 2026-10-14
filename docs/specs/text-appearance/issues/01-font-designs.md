# 01: Native text font designs

**What to build:** Choose standard, rounded or monospaced text in the native inspector, apply
it to selected text or new text, and export the same appearance without changing its content.

**Blocked by:** None (can start after the current saved-color correction's acceptance closes).

**Status:** awaiting-verification (local native/model/export regressions pass; full gate and fresh independent acceptance pending)

- [ ] Standard remains the legacy/default appearance; missing metadata decodes as standard.
- [ ] Rounded and monospaced designs produce observably distinct public-system-font output.
- [ ] Shared measured geometry matches rendered ink, including wrapping, RTL, accents and emoji;
      content maxWidth excludes decoration padding and unavailable fonts refuse explicitly.
- [ ] Creation, selection, duplication and one-step undo/redo retain the chosen appearance.
- [ ] Closed editors and active text composition refuse style mutations without losing input.
- [ ] Native editing reopen/confirm/cancel/zoom uses and retains the same font design.
- [ ] Native EN/PT-BR selector actions and minimum-width dark rendering are verified.
- [ ] Shared renderer exports retain RED source-independence and representation guarantees.
- [ ] Development gates and fresh independent code/native acceptance pass for the slice.
