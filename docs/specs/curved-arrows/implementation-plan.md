# FP-034 implementation plan

Reviewed design and assumptions: [spec.md](spec.md). One functional ticket, internal phases;
no phase alone claims the full feature. Current branch: `feat/onboarding-feature-guide`.

1. **Geometry tracer first.** Domain arrow gains an optional control, preserving straight
   construction/encoding; update all pattern arities atomically. Add a failing real-domain
   coding/transform regression before implementation. Add only curve-specific pure geometry
   needed for midpoint/extrema/transforms. Compare exact legacy JSON, not merely decode success.
2. **Head feasibility and export tracer.** Implement operation-local `ArrowLayout` in Imaging
   with explicit typed geometry failure, actual shaft/head paths, ink bounds and hit support.
   Keep straight drawing unchanged. Prove terminal-branch trimming and a connected filled head
   using independent pixel fixtures before wiring controls. Refuse unsupported degenerates;
   never hide a defect by switching to a straight/open-head style. Use public SDK declarations.
3. **Editor tracer.** Extend EditorStyle/EditorHandle, add curve commands and one visible bend
   handle. Update EditorGeometry, selection handles, gestures, admission and creation. Tests
   exercise EditorModel through EditorHarness; all refusal paths precede history/default edits.
   Numeric X/Y refer to B(0.5); endpoint movement shifts the control by half its delta.
4. **Native tracer.** Add a localized arrow inspector section, selected/mixed values, visible
   bend coordinates and disabled active-input controls; draw bend handle distinctly. Update
   tour strings truthfully. Prefer existing native numeric controls and ChangeCoalescer.
5. **Privacy and integration.** Extend paired-secret PNG/JPEG tests with positive controls,
   transformed layers, masks, magnifiers and nonunit scales. Shared export/canvas rendering
   stays in AnnotationRenderer and ShareSnapshot. Add synthetic bilingual curved-arrow E2E;
   regenerate project only if a new App source requires it.
6. **Acceptance and delivery.** Run focused suites, `scripts/check.sh --unsigned`, named native
   acceptance and the required broader integration gate. Review complexity parsing/coverage,
   Matt Standards/Spec axes, then fresh independent code and source-blind native acceptance.
   Record original FAILs as well as corrections. Update reference matrix, README, changelog,
   BACKLOG and evidence. Commit this ticket with explicit paths and push the working branch.
   Delete only this task's completed ticket in the finishing commit, preserving its spec.

Package build/test and native app/DerivedData each have one lease. An independent backend
worker may own Domain/Imaging and their tests, while main owns Features/native UX/integration;
agree public interfaces before parallel edits, preserve unrelated `docs/handoffs/`, and never
edit a source during its compilation. Source changes ship with observed red-before-green.

Candidate remains 0.12.0/build19 until a release-policy change; no new version bump is proof of
installation. Stable Xcode gates, CAP-01, physical permissions/Spaces/IME/VoiceOver, signing,
notarization, owner-controlled merge and outside-repository installation are separate gates.
