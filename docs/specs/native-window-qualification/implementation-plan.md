# Native window qualification and branch consolidation

Base: `0781aedcbf4e743fd25b87b71356cbb5391aa86b`, 2026-10-15.
Requirements: FR-01/FR-02/FR-04, CAP-01/CAP-02, EDIT-02, UX-02; existing feature
specifications remain authoritative. This is a corrective task, not a new feature.

## What the review changes

1. Treat a failed behavioral oracle as evidence to investigate, not an automatic product defect.
   Current editor-presentation checks inspect compositor visibility of an alpha-zero window;
   capture-focus asks an offscreen, alpha-zero panel to own the keyboard. Neither condition
   matches normal product presentation. Their causal role is still unproven.
2. Establish public AppKit positive/negative controls before changing production focus code.
   Preserve the exact failed observations and distinguish responder assignment, key-window
   ownership, compositor visibility, foreground identity and activation notifications.
3. Keep all capture pixels synthetic. Do not read the personal desktop, drive another app,
   install input monitors, change TCC, force activation or change global settings.
4. Review the whole branch for remaining material defects, while avoiding repeated fixes
   already covered by its independent geometry/export/native acceptance.
5. Make version/documentation, source integration and release qualification separate outcomes.
   The installed0.12.0/build19 remains its original frozen artifact until separately authorized.
6. The adversarial advisor rejected assuming both failures share a fixture cause. Investigate
   compositor visibility and key ownership separately, using the declared2×2 position/opacity
   matrix and identical production calls. A changed oracle must reject an omitted required
   production call; handler dispatch alone never qualifies physical WindowServer delivery.

## Objective and acceptance

Deliver the smallest demonstrated correction and integrate the reviewed working branch into
main when source acceptance is satisfied. Audience: maintainers and AppKit/security reviewers.
Acceptable: a reproducible root cause, regression-sensitive tests, stable gates, independent
acceptance and truthful limits. Excellent: the test signal is simpler and proves the intended
behavior without opaque host assumptions. Satisfaction is not a measurable gate.

Original failure: full stable native run exits1,45/47 scenarios in each language; capture-focus
reports visible=true/key=false/responder=true, while inactive editor presentation reports
occlusion8192/active=false/key=false. Retained reports and original artifact are recorded in
`docs/specs/curved-arrows/local-installation.md`. Stable package/build gate passed683 tests.

## First principles and alternatives

AppKit may decline application activation; an ordinary result window still needs ordering.
A nonactivating selection panel must accept keys while another PID remains foreground.
Assigning a first responder is not proof that WindowServer delivers physical keyboard events.
An offscreen or transparent window is not proof of onscreen compositor visibility. A gate
must include a known-good control at the same seam and a known-bad condition it rejects.

- Conservative: change production focus/ordering with retries or activation. Reject before
  reproduction: it can hide an invalid oracle and violate the active-Space/nonactivation rule.
- Minimal, selected: characterize the current production path and controls; vary one fixture
  condition at a time, then correct only the demonstrated cause. Keep hard assertions for
  supported observations and make unavailable physical qualification explicit.
- Challenge the premise: accept the local-test waiver as full acceptance and merge unchanged.
  Reject: artifact integrity cannot prove the failed native behavior or authorize release.

Five-year view: durable tests should express platform contracts and own their fixtures, rather
than depend on one user's active app, arbitrary delays, window-server internals or repeated
green reruns. Prefer one clear owner for window policy and one truthful observation per assertion.
Avoid introducing a generic window framework or a new dependency for this correction.

## Implementation sequence

- [x] 1. Freeze source/base, inspect existing instructions, specs, ADR-007, callers and tests.
  Inventory preexisting build artifacts. Use stable Xcode27.0/27A266a explicitly; preserve
  `/Applications/Recortia.app`, its rollback bundle, other worktrees and `docs/handoffs/`.
- [x] 2. Complete read-only deep branch audit using `improve deep`; reconcile existing
  `plans/feature-discovery-deep-review.md`. Confirm every proposed defect in source before
  adding it to scope. Record zero findings honestly if the evidence supports zero.
- [x] 3. Obtain a fresh adversarial plan review with the Fable plan-advisor role. Revise this
  plan once for evidence-backed gaps. Research Apple primary docs and installed SDK contracts.
- [x] 4. In an isolated task-owned worktree, run the original focused native command once:
  `scripts/e2e.sh --lang all --only capture-focus,editor-presentation --unsigned` with stable
  `DEVELOPER_DIR` and `RECORTIA_TOOLCHAIN_MODE=stable`. Save command, exit code and reports.
  If a valid oracle cannot be built without protected desktop access, report that precise
  dependency rather than converting unsupported assertions into silent passes.
- [x] 5. Rank3–5 falsifiable hypotheses from that run. First isolate offscreen placement and
  alpha-zero visibility, then app lifecycle/activation state and production focus policy.
  Run each declared offscreen/onscreen×alpha0/alpha1 case once per language with the same
  production calls. Log ordering, occlusion, key status, responder, application activation,
  foreground PID and active-Space status independently. Preserve original failures. Change
  one variable between comparisons; allow one lifecycle follow-up only if the matrix warrants
  it. If matched controls cannot discriminate, stop with a blocked qualification, not a fix.
  Passively observe the already-foreground PID; never drive that application. If controlled
  foreground setup is essential, use an explicitly owned synthetic fixture or request an
  owner-prepared desktop. Observation spans presentation through dismissal/restoration.
- [x] 6. Write one failing behavioral regression at the existing real-controller/native-window
  seam. Implement the smallest verified change. Keep known-good and deliberately invalid
  controls, foreground/activation observations, keyboard transitions and minimized reopening.
  Never weaken a failing contract: require adversarial review of any changed test oracle.
- [x] 7. Review any confirmed non-focus findings, and fix only those with a failing behavioral
  regression. Do not implement optional roadmap ideas, wholesale redesign or speculative cleanup.
- [x] 8. Before final gates, bump a demonstrated correction to0.12.1/build20 in project.yml,
  regenerate the project and update candidate docs while preserving installed0.12.0 evidence.
  Run focused red/green regressions, appropriate RED checks for any imaging/geometry
  change, strict formatting, project freshness and full stable unsigned gate. Run full native
  EN/PT-BR integration on the final code, inspecting affected synthetic renders. Record skips
  distinctly from completed qualification; do not label physical/TCC/Spaces tests passed.
- [x] 9. Run Matt Pocock Standards/Spec adversarial review against origin/main's fixed base;
  include complexity coverage/parse diagnostics. Correct confirmed findings, then run a fresh
  `mneves-verify` context against frozen acceptance, using a different model where required.
- [x] 10. Reconcile README, CHANGELOG, BACKLOG, relevant specs and agent guidance with actual
  final outcomes. A documentation-only result does not justify inventing a source correction.
- [ ] 11. Explicit-path stage, secret scan, Conventional Commit, push, update PR16 and require
  successful exact-head CI. The owner explicitly authorizes merge to main in this request;
  merge only after source acceptance, without tag/release/notarization or branch-policy bypass.
  Required final stable gates, complete bilingual native results, regression-sensitive oracles,
  independent acceptance and exact-head CI must pass. Any remaining required synthetic failure
  or unavailable required positive control blocks merging absent a separate explicit exception.
  Changing production activation, Space policy or pins also triggers the repository's dynamic
  probe/installed-app/fullscreen checks; the existing local-test waiver does not waive those.
- [ ] 12. Restore visible main, verify remote/local history and status, remove only task-owned
  worktrees/processes/unused scratch. Preserve cited evidence, archives/dSYMs, installed backup,
  preexisting caches and unrelated handoffs. Record sizes and what remains.

Steps11–12 are post-commit integration operations. Their completion is recorded by the live
PR16 state and `.scratch/native-window-resume-20261015/integration-result.json`; this tracked
checkpoint does not preclaim a future merge or cleanup.

## Commands, ownership and stopping conditions

All builds: `DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer` and
`RECORTIA_TOOLCHAIN_MODE=stable`. Standard commands are `scripts/check.sh --unsigned`,
`scripts/e2e.sh --lang all --unsigned`, `git diff --check` and project format/freshness checks.
Focused source: `RecortiaApp/E2E/Scenarios+CaptureVisibility.swift`, its native scenario
registration, `Capture/RegionOverlay.swift`, `Editor/EditorWindowManager.swift` and direct
presence-policy callers. Edit production only if a controlled reproduction implicates it.
No source change is presumed necessary by this plan.

### Controlled foreground fixture refinement

The declared matrix completed without production changes. All editor variants passed,
including deliberately offscreen variants; onscreen capture variants passed, while two
offscreen English runs failed key ownership (one also observed another foreground PID).
These observations do not prove one cause for both original failures. The old compositor
oracle is insufficient to prove cross-application ordering without known opaque overlap.

A disposable normal-app prototype established foreground/key/visible/on-active-Space state
using ordinary launch and automatically terminated. Reusing the LSUIElement E2E bundle as
a helper did not establish that precondition (four explicit startup failures, no product
conclusion). The implementation will therefore use a small separate test-only normal-app
target with shared typed state and the existing SpacePolicy/AppPresence owners. It contains
no product services, settings, capture, permissions, networking or input monitors. A runtime
clone/rewrite/re-sign of the E2E bundle is rejected as less maintainable and harder to attest.

This owned helper is the sole exception to the prohibition on driving another application.
Use ordinary launch, known owned PID/window metadata, bounded UUID-scoped coordination and
owned-process termination. A missing readiness/control is a failed or blocked test, not a skip
counted as a pass. Cooperative yielding is allowed only in the explicit activation control;
inactive presentation and selection must not receive it. Do not increase deadlines or force
activation to rescue a failed fixture. Match the successful prototype's ordinary launch.

For visibility, establish a real onscreen opaque editor and a larger known opaque normal-level
cover; require the ordered editor to be fully occluded first. Present through the unchanged
real controller and require visibility without activation. Reject a mutation that omits the
required ordering operation. This measures the controlled overlap, not arbitrary window
ordering. The SDK marks CGWindowListCreate Swift-unavailable, so no unsafe bridge, private API
or unrelated window metadata will be added to obtain a stronger claim.

Main owns product, architecture, this plan, integration and acceptance. Deep advisor owns
only its bounded audit plan. Reviewers are read-only; no overlapping file writers or builds.
Ordinary implementation must remain in the repository/task worktree. Installed app, global
settings, credentials, personal data, other repositories and published releases are out of scope.
Stop for conflicting writers, an essential inaccessible test capability or destructive action
not covered by the owner's exact current authorization. Do not manufacture100% qualification.

## Primary-source checks

- Apple `NSWindow.occlusionState`: at least part of the window is visible when the visible bit
  is set; installed SDK notes transparent windows *may* count as visible, not that they must.
  https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.property
- Apple `orderFrontRegardless`: ordering across application boundaries has different semantics
  from normal ordering. https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless()
- Apple nonactivating panel key behavior:
  https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded
- Installed source of truth: stable MacOSX27.0.sdk AppKit NSWindow.h/NSPanel.h. The browsing
  tool rejected Markdown content type; direct HTTPS retrieval succeeded for all four Apple
  documents and is retained in `.scratch/native-window-review-20261015/*-apple.md`.
