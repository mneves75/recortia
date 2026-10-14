# 01: Native text font designs

**What to build:** Choose standard, rounded or monospaced text in the native inspector, apply
it to selected text or new text, and export the same appearance without changing its content.

**Blocked by:** None (can start after the current saved-color correction's acceptance closes).

**Status:** verified-development (f1852b7; full gate, independent code/security and source-blind native acceptance pass; physical/stable release qualification separate)

- [x] Standard remains the legacy/default appearance; missing metadata decodes as standard.
- [x] Rounded and monospaced designs produce observably distinct public-system-font output.
- [x] Shared measured geometry matches rendered ink, including wrapping, RTL, accents and emoji;
      content maxWidth excludes decoration padding and unavailable fonts refuse explicitly.
- [x] Creation, selection, duplication and one-step undo/redo retain the chosen appearance.
- [x] Closed editors and active text composition refuse style mutations without losing input.
- [x] Native editing reopen/confirm/cancel/zoom uses and retains the same font design.
- [x] Native EN/PT-BR selector actions and minimum-width dark rendering are verified.
- [x] Shared renderer exports retain RED source-independence and representation guarantees.
- [x] Development gates and fresh independent code/native acceptance pass for the slice.

Evidence: ../acceptance-verdict.md and ../review-evidence.md. Actual font-unavailability,
physical IME/VoiceOver/Spaces, macOS15 runtime and stable-Xcode release checks remain separate.
