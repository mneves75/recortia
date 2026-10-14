# 02: Outlined and boxed text appearances

**What to build:** Extend the same native Text Style selector with outlined, boxed, rounded-boxed
and monospaced-boxed text, preserving editing, geometry, export and privacy behavior.

**Blocked by:** None; ticket01 verified-development. Follow ../implementation-plan.md.

**Status:** integrated; formal native acceptance blocked by missing25% raster evidence,
with its one correction in progress. See ../decoration-review-evidence.md.

- [x] Four decorations have independently checked glyph/box output, padding and outside bounds.
- [x] Background color/alpha controls describe actual defaults and remain effective.
- [x] Selected and newly created text retain styles across undo/redo and duplication.
- [x] Mixed selection does not restyle unrelated annotations; Unicode/wrapping remains intact.
- [x] Every style passes paired-secret masked exports, edge/cache and clean-representation tests.
- [x] Native selector interaction and bilingual standard/minimum-width dark renders are verified.
- [ ] Development gates and independent adversarial/native acceptance pass for this slice.
