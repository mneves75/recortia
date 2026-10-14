# 02: Outlined and boxed text appearances

**What to build:** Extend the same native Text Style selector with outlined, boxed, rounded-boxed
and monospaced-boxed text, preserving editing, geometry, export and privacy behavior.

**Blocked by:** None; ticket01 verified-development. Follow ../implementation-plan.md.

**Status:** in-progress (backend outlined-pixel tracer and native input feasibility)

- [ ] Four decorations have independently checked glyph/box output, padding and outside bounds.
- [ ] Background color/alpha controls describe actual defaults and remain effective.
- [ ] Selected and newly created text retain styles across undo/redo and duplication.
- [ ] Mixed selection does not restyle unrelated annotations; Unicode/wrapping remains intact.
- [ ] Every style passes paired-secret masked exports, edge/cache and clean-representation tests.
- [ ] Native selector interaction and bilingual standard/minimum-width dark renders are verified.
- [ ] Development gates and independent adversarial/native acceptance pass for this slice.
