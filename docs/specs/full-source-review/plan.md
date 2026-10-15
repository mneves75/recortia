# Full-source review 2026-10 — findings and implementation plan

Owner request (2026-10-15): review all source code, fix the problems found test-first, update the
docs, bump the version, and merge to `main`. Target: `main` at `5268d48` (0.12.1/build20,
untagged), branch `review/full-source-0.12.2`, PR #17. Candidate after fixes: 0.12.2/build21.

## Method

- Four independent read-only reviewers (gpt-6.1-sol, xhigh, fresh contexts, no edits/builds),
  each owning one partition and attacking the AGENTS.md invariants: A Domain+Imaging+Fixtures,
  B Features, C MacPlatform+app shell, D Editor/Onboarding UI + scripts/CI/release + the E2E
  isolation boundary. Every finding is a hypothesis until a red test fails on it.
- Main session: the hosted-CI font-resolution incidents, triage of every finding against the
  code, and the UI fixes. Package and script fixes go to one Codex lane (owner routing rule).
- Complexity navigation (`cccc 1.8.0 --no-cache --min 0`, 133/133 production Swift files outside
  E2E; 35 parse errors in 6 files, so their metrics are partial): highest cognitive scores are
  `ScrollSessionModel.collect` (52), `EditorModel+Gestures.commitCreation` (49),
  `QRBitstream.parse` (49), `RenderEngine.validate` (41) and `EditorModel.setFrame` (34). Scores
  steer reading only; no finding below rests on them.
- Bound: one review round, then one rerun after corrections. Fix confirmed P0–P2 in this branch;
  P3 and design-level items become proposals in BACKLOG.

## Findings and triage

Verdicts: **confirmed** = the defect is visible in the cited code and the red test is specified;
**deferred** = real but P3 (no current trigger or visual-only) and recorded as a proposal;
**rejected** = disproved, with the reason.

| ID | Reviewer P | Triage | Finding | Owner |
|---|---|---|---|---|
| F-1 | — | P1 confirmed (CI) | Designed system fonts resolved concurrently through AppKit; hosted CI twice reported `unavailableFont` | Codex |
| B-1 | P1 | P1 confirmed | An import that completes during a move/resize drag is overwritten by the gesture's `original` snapshot | Codex |
| C-1 | P1 | P1 confirmed | Automatic scrolling re-discovers the frontmost window on its first step instead of using the frame source's bound window, so a fast app switch can post a scroll event to another app | Codex |
| C-2 | P2 | P2 to prove | Stopping a scroll source while it is `.starting` does not stop its producer; a suspended startup can begin capturing afterwards | Codex |
| D-1 | P1 | P1 confirmed | `release.sh` deletes an existing tag's archive, dSYMs and notarized DMG before re-running the gate | Codex |
| A-2 | P2 | P2 confirmed (privacy hardening) | `AffineMap.inverted()` can return a non-finite inverse; `Document.sourceRegions` then skips the layer instead of failing closed | Codex |
| B-3 | P2 | P2 confirmed | `EditorModel.close()` promises to cancel in-flight work but leaves its export snapshot running while releasing its assets | Codex |
| B-4 | P2 | P2 confirmed | Resume after Stop (append still settling) re-enters collecting and can send a real scroll event to the target app | Codex |
| B-5 | P2 | P2 confirmed | Text editing does not end a preceding continuous adjustment, so one Undo reverts both | Codex |
| D-3 | P2 | P2 confirmed | `e2e.sh` never runs `doctor.sh`; it defaults to the host's RC `Xcode.app` without labeling the evidence | Codex |
| D-4 | P2 | P2 confirmed | `check-project-fresh.sh` passes locally without XcodeGen, and `release.sh`'s gate inherits the skip | Codex |
| A-1 | P2 | P3 deferred | Block-mean colour signatures can call a within-block colour permutation stationary (requires constructed content) | proposal |
| A-3 | P2 | P3 deferred | Scroll admission's peak estimate omits matcher scratch (medium confidence, unmeasured) | proposal |
| B-2 | P2 | P3 deferred | Caller-task cancellation is not propagated into `ExportCoordinator.run`; no caller cancels its task today | proposal |
| D-2 | P2 | P3 deferred | Native text editing paints glyphs opaque while the committed render applies annotation opacity | proposal |

Partition C cleared still-capture overlap/cancellation, multi-display geometry, self-exclusion,
ShareSnapshot-only sinks, atomic saves, drag leases, GitHub upload bounds/redirect refusal,
Keychain scoping, shortcut ownership, MainActor isolation and quit/login flows.

### F-1 Font resolution under concurrency (main-session lead)

Facts. `TextLayout.nativeFont` (Imaging/TextLayout.swift:28-42) calls `NSFont.systemFont`,
`NSFontDescriptor.withDesign` and `NSFont(descriptor:size:)` — both last two nullable — and is
called from the main actor (editor admission, canvas) and from export rendering off-main. CI
`swift test --parallel` runs both at once. Hosted run 38652457209 failed
`setTextAppearance(.monospaced)` on the main actor; main run 38795897584 attempt 1 failed an
off-main export with `unavailableFont(.roundedBoxed)`; both replays passed unchanged. In the
stable SDK (MacOSX27.0, Xcode 27.0 27A266a), `NSFont.h` is inside
`NS_HEADER_AUDIT_BEGIN(nullability, sendability)` and neither `NSFont` nor `NSFontDescriptor`
is `NS_SWIFT_SENDABLE`; Apple's thread-safety summary gives no guarantee for fonts, while Core
Text documents its font objects as usable from multiple threads. Locally, 300 cold processes ×
512 concurrent resolutions (scratch probe) and the new stress test produced zero failures, so
the race was not reproduced on this macOS 27.2 host.

Options considered:
1. **Serialize AppKit font resolution behind one process-wide lock (chosen).** Smallest change;
   keeps the exact same fonts (sizes keep their optical-size descriptors), the public API and the
   NSFont identity that native editing and E2E compare. Conforms the non-Sendable usage to
   "one thread at a time".
2. Resolve each design's descriptor once and derive sizes with `CTFontCreateWithFontDescriptor`.
   Rejected: a cached descriptor carries its original size's optical attributes, changing glyph
   metrics at other sizes, and alters the NSFont identity the editor compares.
3. Confine resolution to the main actor and pass fonts to export. Rejected: export would await
   the main actor from rendering (deadlock/latency risk) and the change crosses module contracts.

Evidence plan: the stress regression `TextLayoutConcurrencyTests` landed first (6b5e908) and
runs on the hosted runner before the fix; its result is recorded here whether red or green. If
it stays green before the fix, the lock remains a hardening justified by the SDK's sendability
audit, and the incident stays "cause not established".

## Fix plan (test first, one commit per finding)

Each item: write the red test, run it and keep the failing log under
`.scratch/full-source-review-20261015/`, then the smallest fix, then the focused suite.

- **F-1** — `TextLayout.nativeFont`: hold a process-wide `Synchronization.Mutex` while calling
  the three AppKit APIs. Test: `TextLayoutConcurrencyTests` (exists).
- **B-1** — before `addImageLayer` (and any other async document edit) commits, settle an
  active move/resize gesture at its current state (as pointer-up does) so its undo group closes;
  the import is its own undo step. Test in `EditorCompositionTests`: suspended import, begin and
  advance a move, resolve the import, continue/end the drag; the layer survives and Undo removes
  only the import, then only the move.
- **C-1** — `LiveAutoScroll` scrolls only the window the frame source bound at start
  (`LiveScrollTargetChecker`); it rechecks that binding after its asynchronous window discovery
  and refuses (target lost) otherwise. Extract the window choice as a pure function so a
  synthetic E2E check proves a different frontmost window is refused and the bound one accepted.
- **C-2** — stopping a `.starting` `ScrollFrameSource` stops its producer and invalidates the
  startup; the producer checks that generation after preparing the session and before
  `startCapture`. Test in `ScrollFrameSourceTests` with a suspended-startup producer.
- **D-1** — `release.sh`: refuse to run when the tagged output directory already exists (name it
  and tell the owner to move it); dry runs may still replace their own `-dev` directory. Test in
  `scripts/test-release-contract.py`.
- **A-2** — `AffineMap.inverted()` throws `GeometryError.nonFinite` when any inverse coefficient
  is non-finite; `sourceRegions` already maps that to `unmappableTransform` (fail closed). Tests:
  the overflow matrix in `GeometryTests`, and a RED-family test that a mask over a layer whose
  inverse overflows is refused rather than skipped.
- **B-3** — operations carry their `DocumentID`; `ExportCoordinator.cancel(documentID:)` cancels
  only that document's snapshot/upload; `EditorModel.close()` calls it. Test in
  `EditorExportTests` with a cancellation-aware suspended exporter plus a control that closing a
  different document does not cancel.
- **B-4** — `resume()` and `autoStep` refuse while `pendingFinish != nil`. Test in
  `ScrollSessionModelEndingTests`: held append, pause, stop, resume; scroller step count unchanged.
- **B-5** — `beginEditingText` ends the preceding continuous adjustment after admission. Test in
  `EditorReplayTests`: open colour adjustment, edit text, Undo reverts only the text.
- **D-3** — `e2e.sh` runs `scripts/doctor.sh` before building or launching. Test in
  `scripts/test-doctor.py` (or the e2e isolation test) proving an unreviewed toolchain is
  rejected before any build.
- **D-4** — `check-project-fresh.sh` fails when XcodeGen is missing. Update
  `scripts/test-project-freshness.py`, which today asserts the local skip.

## Acceptance

- Every confirmed finding has a recorded red run and a green run; no existing test weakened.
- Stable gate: `DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer
  RECORTIA_TOOLCHAIN_MODE=stable scripts/check.sh --unsigned` passes.
- Full bilingual native E2E (`scripts/e2e.sh --lang all --unsigned`, output to a file) passes.
- `code-review` (Standards/Spec) on the branch diff, the `reviewer` agent, and a different-model
  `mneves-verify` acceptance; confirmed findings fixed, one rerun.
- Exact-head CI green before the squash merge; main CI watched after it. A recurrence of F-1 on
  main after the lock means the fix failed, not a flake to rerun.

## Not in scope

No tag, notarization, release or reinstall (the installed app stays 0.12.0/build19). No website
or app redesign: this repository has no web frontend, and the native UI follows AppKit/SwiftUI
controls per AGENTS.md. Physical keyboard/IME/VoiceOver/TCC/Spaces qualification stays separate.
