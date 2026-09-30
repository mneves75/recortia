# Implementation plan and task contracts

**Status:** The approved v1 milestones have a beta implementation. BACKLOG.json records current
task status, signed local-install evidence, and outstanding manual qualification; this file defines
task contracts rather than a build log. Local installation does not complete notarized distribution
or the 1.0 release contract.

## Execution policy

The owner approved FR-01…FR-14 implementation on 2026-09-26 (AGENTS.md). The original
docs/handoff/START_HERE.md is historical; FR-15/FR-16 still require separate approval. Publishing,
live screen access, credentials, and external side effects require explicit authority. A single
coherent vertical slice must remain buildable.

The baseline critical path is M0 -> M1 -> M2 -> M3 -> M4/M5 -> M6. M4 and M5 may use isolated worktrees after 0.1, but renderer/geometry changes need a single integrator. FP-023 and FP-024 may proceed independently after FP-022 with separate ownership.

Every task below inherits SPEC.md and AGENTS.md. Its verification IDs resolve to ACCEPTANCE_TESTS.md. Tests shared with earlier tasks must continue to pass; a feature addition does not reset earlier gates.

## Milestone map

| Milestone | Outcome | Exit condition |
|---|---|---|
| M0 | Feasibility and approved plan | Complete assigned task contracts and record unresolved hardware/permission blocks explicitly. |
| M1 | Small native vertical slice | Complete assigned task contracts and record unresolved hardware/permission blocks explicitly. |
| M2 | Editor, secure exports, and pins | Complete assigned task contracts and record unresolved hardware/permission blocks explicitly. |
| M3 | Local OCR and useful 0.1 candidate | Complete assigned task contracts and record unresolved hardware/permission blocks explicitly. |
| M4 | Trustworthy scrolling | Complete assigned task contracts and record unresolved hardware/permission blocks explicitly. |
| M5 | Pixel tools and composition | Complete assigned task contracts and record unresolved hardware/permission blocks explicitly. |
| M6 | Qualified open-source 1.0 candidate | Complete assigned task contracts and record unresolved hardware/permission blocks explicitly. |

## M0 — Feasibility and approved plan

FP-001 through FP-003. Read-only inventory is first; code spikes and live test access require explicit approval. Resolve high-risk capture, privacy, and matching assumptions before building the full editor.

### FP-001 — Inventory repository and freeze verified toolchain

**Depends on:** None  
**Requirements:** FR-01, FR-14  
**Verification:** REL-01

Read the real repository, preserve existing work, record the Mac/toolchain/SDK state, and identify proposed versus existing paths.

**Deliver:** Repository audit; Observed TOOLCHAIN.json fields; ADR-001 native stack and deployment baseline.

**Complete when:** An owner-reviewed plan distinguishes verified facts, unsupported environment checks, and genuinely blocking decisions. No application edits before approval.

### FP-002 — Prove capture, geometry, and permission feasibility

**Depends on:** FP-001  
**Requirements:** FR-02, FR-10  
**Verification:** PERM-01, CAP-01, GEO-01

After approval and explicit live-test consent, build a minimal capture spike against a synthetic test desktop and investigate the selected permission/sandbox profile.

**Deliver:** Disposable capture spike; Per-display geometry observations; ADR-002 permission and sandbox decision.

**Complete when:** Record real still-capture results, app-window exclusion, a mixed-DPI test or explicit hardware block, and a reasoned choice about non-sandboxed automatic scrolling.

### FP-003 — Prove privacy rendering and scroll-matching risks

**Depends on:** FP-001  
**Requirements:** FR-06, FR-10  
**Verification:** RED-01, SCR-01, SCR-02

Use synthetic images to prototype pre-filter opaque masking and a minimal overlap matcher before investing in UI polish.

**Deliver:** Independent secret-region fixture generator; Scroll frame corpus seed; Risk/feasibility report.

**Complete when:** Demonstrate the intended redaction information-dependence test and show both a successful and an intentionally rejected ambiguous stitch; report any unrun code honestly.

## M1 — Small native vertical slice

FP-004 through FP-008. Deliver a native menu command -> capture/import -> preview path, with typed geometry, bounded input, cancellation, and real build/test entrypoints.

### FP-004 — Create the approved native project and test entrypoints

**Depends on:** FP-002, FP-003  
**Requirements:** FR-01, FR-14  
**Verification:** REL-01

Create or adapt the approved app target, local package targets, shared schemes, formatting configuration, and unsigned CI entrypoints.

**Deliver:** Recortia.xcodeproj or approved existing equivalent; Packages/RecortiaKit; scripts/doctor.sh and scripts/check.sh; Read-only PR workflow.

**Complete when:** A clean Mac checkout builds the skeleton and runs a real domain test without release credentials. Dependency locks and exact script behavior are documented.

### FP-005 — Implement typed geometry and domain contracts

**Depends on:** FP-004  
**Requirements:** FR-02, FR-04, FR-06  
**Verification:** GEO-02, EDIT-01

Implement coordinate-space types, safe transforms, request/revision identity, limits, document values, and explicit state transitions.

**Deliver:** Domain geometry/model/state files; Parameterized geometry and transition tests.

**Complete when:** Round-trip, outward mask rounding, invalid-input, overflow, and illegal-transition tests pass without UI dependencies.

### FP-006 — Build the menu bar, settings foundation, and shortcuts

**Depends on:** FP-004  
**Requirements:** FR-01, FR-14  
**Verification:** PERM-01, UX-01

Create the native lifecycle, menu commands, onboarding, shortcut recorder with macOS-style defaults (ADR-005), localization foundation, and settings.

**Deliver:** App composition root; Menu/settings/onboarding UI; String Catalog; Reviewed shortcut dependency resolution.

**Complete when:** The app launches without intrusive permission prompts, exposes keyboard-accessible commands, reports shortcut registration failure and shortcuts macOS still uses, and starts with no automatic side effects beyond writing the default shortcuts once.

### FP-007 — Implement the still-capture vertical slice

**Depends on:** FP-005, FP-006  
**Requirements:** FR-02  
**Verification:** CAP-01, CAP-02, PERM-02, GEO-01

Implement ScreenCaptureKit still capture, source choice, overlays, delay/repeat, exclusion, and cancellation through to a simple image preview.

**Deliver:** Capture adapter and permission state; Selection overlays/HUD; Capture coordinator tests.

**Complete when:** Real capture works for the declared modes and source geometry, with one active request, no idle stream, no self-overlay contamination, and safe late-callback handling.

### FP-008 — Implement bounded local image import

**Depends on:** FP-005, FP-006  
**Requirements:** FR-03  
**Verification:** IO-01, PRIV-01

Implement explicit PNG/JPEG file, paste, and drop-in actions using bounded decoding and canonical image orientation/color.

**Deliver:** Image decoder/import adapter; Input budget enforcement; Corrupt/oversized fixtures.

**Complete when:** Valid imports render; unsafe/unsupported inputs fail before uncontrolled allocation. No clipboard polling, remote fetch, or original-file mutation occurs.

## M2 — Editor, secure exports, and pins

FP-009 through FP-013. Deliver capture -> explain -> redact -> copy/save/drag. No new export-capable surface bypasses the privacy pipeline.

### FP-009 — Build the document editor and command undo

**Depends on:** FP-007, FP-008  
**Requirements:** FR-04  
**Verification:** EDIT-01, EDIT-02, GEO-02

Implement the native canvas, document/view transforms, crop/resize/zoom/pan, selection, and bounded command-based undo.

**Deliver:** Editor canvas and controller; Command history; Deterministic editor replay tests.

**Complete when:** Undo/redo and geometry remain correct at all specified zooms, and one gesture produces one bounded undo group.

### FP-010 — Add essential annotation tools

**Depends on:** FP-009  
**Requirements:** FR-05  
**Verification:** EDIT-01, EDIT-02, UX-01

Implement text, arrow, rectangle, ellipse, freehand, highlighter, and numbered-step tools with accessible controls.

**Deliver:** Typed annotation payloads and renderer; Tool inspector; Unicode and input-method tests.

**Complete when:** Each supported tool creates/edits/replays deterministically, honors focus/input composition, and has no stub or inaccessible essential action.

### FP-011 — Implement secure rendering and redaction

**Depends on:** FP-009, FP-010  
**Requirements:** FR-06  
**Verification:** RED-01, RED-02, RED-03, RED-04

Implement source-bound masks, output coverage, privacy epochs, effect ordering, and flattened render snapshots. Label cosmetic effects separately.

**Deliver:** Privacy-aware render pipeline; Mask geometry and cache invalidation; Redaction regression suite.

**Complete when:** All available sink-independent redaction tests pass; changing only covered source pixels cannot alter sanitized rendered pixels. No superficial overlay qualifies.

### FP-012 — Implement safe save, clipboard, and drag-out

**Depends on:** FP-011  
**Requirements:** FR-07  
**Verification:** EXP-01, EXP-02, RED-01, RED-02, PRIV-01

Create ShareSnapshot encoding, metadata/type allowlists, explicit export commits, atomic file handling, and file-promise lifetime management.

**Deliver:** PNG/JPEG encoder; Clipboard/file/drag adapters; Failure injection and metadata-inspection tests.

**Complete when:** Every sink accepts only sanitized snapshot bytes. Failed work preserves existing destinations/clipboard where applicable and never reports false success.

### FP-013 — Implement bounded reference pins

**Depends on:** FP-012  
**Requirements:** FR-09  
**Verification:** PIN-01, RED-03

Add visible floating references with lifecycle, opacity/zoom, budget enforcement, and privacy-epoch invalidation.

**Deliver:** Pin panel/controller; Snapshot retention policy; Pin lifecycle tests.

**Complete when:** Five-pin and budget limits work; pins remain closeable and do not silently intercept unrelated interactions or leak stale exports.

## M3 — Local OCR and useful 0.1 candidate

FP-014 through FP-015. Qualify the local daily-use subset. Do not advertise scrolling or pro-tool parity yet.

### FP-014 — Implement local OCR and QR

**Depends on:** FP-012  
**Requirements:** FR-08  
**Verification:** OCR-01, OCR-02, RED-03, PERM-01

Integrate Vision behind the tested adapter, query supported languages, preserve raw-text semantics, and treat QR payloads as untrusted.

**Deliver:** OCR/QR service and review UI; Versioned EN/PT corpus; Revision-aware result handling.

**Complete when:** Recognition works offline in the validated environment, aligns boxes correctly, respects masks/cancellation, and never performs a QR-triggered action automatically.

### FP-015 — Qualify the useful 0.1 release candidate

**Depends on:** FP-013, FP-014  
**Requirements:** FR-01, FR-02, FR-03, FR-04, FR-05, FR-06, FR-07, FR-08, FR-09, FR-14  
**Verification:** UX-01, PRIV-01, PERF-01, REL-01, REL-02

Review the 0.1 scope, perform baseline accessibility/privacy/performance checks, establish licensing/build docs, and prepare a signed candidate only with the required consent.

**Deliver:** 0.1 requirement/evidence matrix; Initial OSS policy files; Protected signing/notarization procedure; Known limitations.

**Complete when:** All 0.1 gates pass or the scope is visibly reduced through review. Signing checks are real or marked blocked; public publishing remains a separate action.

## M4 — Trustworthy scrolling

FP-016 through FP-018. Manual first, separately consented automatic control second, real compatibility qualification third.

### FP-016 — Implement manual scrolling capture

**Depends on:** FP-015  
**Requirements:** FR-10  
**Verification:** SCR-01, SCR-02, SCR-04, CAP-02

Integrate a bounded user-visible capture stream, frame stability, overlap estimation, confidence gating, seam preview, and partial-result review.

**Deliver:** Manual scroll session/coordinator; Bounded matching/assembly pipeline; Fixture-driven stitch diagnostics.

**Complete when:** Known sequences reconstruct correctly; ambiguous matches pause/reject instead of fabricating success. Stop and resource limits remain responsive.

### FP-017 — Add separately consented automatic scrolling

**Depends on:** FP-016  
**Requirements:** FR-10  
**Verification:** PERM-01, PERM-02, SCR-03

Implement minimal targeted scrolling only within the approved permission/sandbox design, preserving manual fallback.

**Deliver:** Automatic-scroll adapter; Accessibility explanation and denial flow; Target/focus safety checks.

**Complete when:** No Accessibility request occurs before choosing automatic mode. Target changes stop control; denial keeps manual mode usable. No typing/global event logging is added.

### FP-018 — Qualify scrolling compatibility and failure behavior

**Depends on:** FP-017  
**Requirements:** FR-10  
**Verification:** SCR-01, SCR-02, SCR-03, SCR-04, PERF-01

Validate supported browsers/native fixtures, fixed bands, lazy reflow, duplicate rows, direction changes, and scroll-modifier failure cases.

**Deliver:** Versioned real-app compatibility matrix; Held-out matching evaluation; Documented manual recovery flow.

**Complete when:** Publish only evidence-backed supported targets. Every corrupted/uncertain case is rejected, paused, or explicitly marked partial; resource tests include final encoding.

## M5 — Pixel tools and composition

FP-019 through FP-021. Add inspection and presentation without destabilizing capture or compromising source-mask propagation.

### FP-019 — Implement loupe, measurements, and sRGB inspection

**Depends on:** FP-015  
**Requirements:** FR-11  
**Verification:** PIX-01, GEO-01, GEO-02

Add a nearest-neighbor loupe, labeled pixel/point dimensions, ruler anchors, and canonical sRGB HEX/RGB copy.

**Deliver:** Pixel inspector/ruler UI; Known-color/geometry fixtures; Source-space sampling tests.

**Complete when:** Measurements and colors match declared fixture values independently of editor zoom; imported images never get fabricated screen scaling.

### FP-020 — Implement multiple-image composition

**Depends on:** FP-015  
**Requirements:** FR-12  
**Verification:** COMP-01, RED-01, RED-03, EDIT-01

Add image layers, stable transforms, z-order, transparency, side-by-side layout, and source-mask propagation across duplicate asset references.

**Deliver:** Image-layer commands and composite renderer; Transform mapping tests; Composite privacy regressions.

**Complete when:** Composites preserve aspect ratio, geometry, undo, and masks. Unsupported mappings fail safely before any export.

### FP-021 — Add presentation effects and safe magnifiers

**Depends on:** FP-020  
**Requirements:** FR-13  
**Verification:** COMP-01, RED-01, RED-02, RED-03, PERF-01

Implement backgrounds/padding/corners/shadows and then spotlight/magnifier, reusing the approved sanitized render graph.

**Deliver:** Effect models and native inspectors; Cycle checks and cache rules; Per-effect export/privacy fixtures.

**Complete when:** Every derived effect samples sanitized sources, rejects cycles, matches the preview, and stays within the resource budget.

## M6 — Qualified open-source 1.0 candidate

FP-022 through FP-025. Finish accessibility, localization, performance, privacy, signing/update checks, contributor handoff, and truthful release evidence.

### FP-022 — Finish accessibility, localization, and native interaction

**Depends on:** FP-018, FP-019, FP-021  
**Requirements:** FR-01, FR-14  
**Verification:** UX-01, EDIT-02, PIN-01

Audit all completed surfaces for keyboard/VoiceOver use, input methods, adaptive appearance, multi-window focus, and EN/PT-BR strings.

**Deliver:** Accessibility audit with actual evidence; Complete String Catalog translations; Native interaction regression list.

**Complete when:** Essential workflows are usable through the stated accessibility paths. Remaining limitations are disclosed rather than labeled fully accessible.

### FP-023 — Qualify resource, lifecycle, and privacy budgets

**Depends on:** FP-022  
**Requirements:** FR-02, FR-06, FR-07, FR-10, FR-14  
**Verification:** PERF-01, PRIV-01, PERM-02, RED-01, RED-02, SCR-04

Run physical-Mac performance/soak tests and inspect egress, app-controlled persistence, retained objects, diagnostics, and failure boundaries.

**Deliver:** Performance and memory report; Privacy evidence; Resolved or reviewed release-blocking defects.

**Complete when:** Record p50/p95/sample counts and exact environments. No fabricated hardware results, silent budget changes, live capture archive, or content-bearing logs.

### FP-024 — Implement and stage the signed updater

**Depends on:** FP-022  
**Requirements:** FR-14  
**Verification:** REL-02, PRIV-01

Integrate a reviewed stable Sparkle build, opt-in update checks, signed archives, compatibility filtering, and an actual staging recovery procedure.

**Deliver:** Updater adapter/settings; Protected update signing procedure; Tamper/interruption/compatibility evidence.

**Complete when:** Invalid updates are rejected, default installs remain offline, and the working app survives failure. No release/update key is exposed to untrusted jobs.

### FP-025 — Complete open-source handoff and 1.0 release qualification

**Depends on:** FP-023, FP-024  
**Requirements:** FR-01, FR-02, FR-03, FR-04, FR-05, FR-06, FR-07, FR-08, FR-09, FR-10, FR-11, FR-12, FR-13, FR-14  
**Verification:** REL-01, REL-02, UX-01, PRIV-01

Assemble the reviewed source tag, license/notice inventory, reproducible inputs, SBOM, contributor/security docs, final compatibility matrix, and clean-install evidence.

**Deliver:** 1.0 traceability and evidence matrix; OSS documentation; Signed/notarized candidate and artifact hashes when authorized; Release checklist.

**Complete when:** The release candidate meets its named scope without fake parity/security claims. The maintainer approves any publish action separately; unrun gates remain visibly unrun.

## Required task evidence record

```json
{
  "task_id": "FP-000",
  "status": "awaiting_manual_validation",
  "source_commit": null,
  "environment": null,
  "commands_run": [],
  "tests_passed": [],
  "tests_failed": [],
  "tests_unrun": [],
  "artifact_paths": [],
  "limitations": [],
  "reviewer": null
}
```

The example is an empty schema illustration, not evidence for a real task. Replace FP-000 with an assigned identifier and fill only observed results. Do not invent source commits, reviewer names, command output, or artifacts.

## Stop conditions

Stop the affected operation, preserve safe progress, and report when the next action would require unapproved live data/credentials, an insecure export fallback, disabling platform security, exceeding a resource budget, changing the license/architecture, overwriting unrelated work, or faking unavailable hardware validation. Ordinary difficulties inside an approved task are handled with tests and bounded fixes, not repeated approval requests.

## Deferred backlog

FR-15 (S3 sharing) and FR-16 (automation/on-device assistance) require separate design, tests, threat-model updates, and approval. Their high-level constraints are in SPEC.md. Do not prebuild unused provider abstractions, a server, an agent runtime, or model downloads in the v1 implementation.
