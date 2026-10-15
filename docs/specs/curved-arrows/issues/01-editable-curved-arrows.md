# 01: Create, bend and export editable curved arrows

**What to build:** A complete curved-arrow workflow: choose Curved, draw an arrow, adjust its
visible bend or endpoints with pointer/native fields, straighten, undo/redo, and export through
the existing sanitized sharing path. Keep straight arrows unchanged and reject invalid curves.

**Blocked by:** None (can start immediately). Candidate delivery remains blocked separately
by unresolved CAP-01 integration qualification.

**Status:** in-progress (source implemented; full gate and independent acceptance pending)

- [x] Existing straight encoding/rendering and curved round-trip have behavioral regressions.
- [x] Actual curve/head geometry is shared by rendering, selection and ink bounds.
- [x] Creation/default, selected toggle, mixed selection and visible bend fields work end to end.
- [x] Endpoint/midpoint/frame transforms, duplicate, cancel and single-action Undo/Redo pass.
- [x] Invalid/closed/active-input requests refuse atomically, preserving defaults and history.
- [x] Actual PNG/JPEG pixels prove junction/opacity and secure masks/magnifiers.
- [x] Native EN/PT controls, tour and 25%/200% painting are inspected.
- [ ] Required gate, two-axis adversarial review and fresh independent acceptance are recorded.
