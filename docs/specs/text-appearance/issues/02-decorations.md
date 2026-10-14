# 02: Outlined and boxed text appearances

**What to build:** Extend the same native Text Style picker with outlined, boxed, rounded-boxed
and monospaced-boxed text, preserving editing, geometry, export and privacy behavior.

**Blocked by:** 01: Native text font designs.

**Status:** ready-for-agent

- [ ] Four decorations have independently checked glyph/box output, padding and outside bounds.
- [ ] Background color/alpha controls describe actual defaults and remain effective.
- [ ] Selected and newly created text retain styles across undo/redo and duplication.
- [ ] Mixed selection does not restyle unrelated annotations; Unicode/wrapping remains intact.
- [ ] Every style passes paired-secret masked exports, edge/cache and clean-representation tests.
- [ ] Native picker interaction and bilingual standard/minimum-width dark renders are verified.
- [ ] Development gates and independent adversarial/native acceptance pass for this slice.
