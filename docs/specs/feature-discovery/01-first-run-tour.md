# 01: Complete and replay the first-run feature tour

**What to build:** Explain all implemented Recortia feature families in a skippable native,
bilingual first-run tour; allow replay from the menu without resetting preferences.

**Blocked by:** Stable Xcode availability and full-suite keyboard/occlusion qualification.

**Status:** source verified; awaiting manual validation. Independent code acceptance PASS;
overall release acceptance BLOCKED. See review-evidence.md and acceptance-verdict.md.

- [x] Ordered navigation, Back, Skip and completion persist correctly.
- [x] Replay preserves completion and every export/permission preference.
- [x] All implemented feature families, opt-ins and limitations are explained.
- [x] Native controls, progress, scrollable content and complete pt-BR strings (physical keyboard/VoiceOver unrun).
- [x] No capture permission, real export or network request occurs in the synthetic tour.
- [ ] Stable gate, bilingual E2E and independent adversarial acceptance evidence attached.
