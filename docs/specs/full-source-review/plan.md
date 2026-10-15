# Full-source review 2026-10 — findings, evidence ledger and implementation plan

Owner request (2026-10-15): review all source code, fix the problems found test-first, update the
docs, bump the version, and merge to `main`. Target: `main` at `5268d48` (0.12.1/build20,
untagged), branch `review/full-source-0.12.2`, PR #17. Candidate after fixes: 0.12.2/build21.

## Method

- Four independent read-only reviewers (gpt-6.1-sol, xhigh, fresh contexts, no edits/builds),
  each owning one partition and attacking the AGENTS.md invariants: A Domain+Imaging+Fixtures,
  B Features, C MacPlatform+app shell, D Editor/Onboarding UI + scripts/CI/release + the E2E
  isolation boundary. Main session: the hosted-CI font incidents and triage of every finding
  against the code. An adversarial read-only plan review (gpt-6-astra, high) then challenged
  the triage, the font hypothesis, the overall approach and the acceptance; its changes are
  listed under "What the plan review changed".
- Complexity navigation (`cccc 1.8.0 --no-cache --min 0`, 133/133 production Swift files outside
  E2E; 35 parse errors in 6 files, so their metrics are partial): highest cognitive scores are
  `ScrollSessionModel.collect` (52), `EditorModel+Gestures.commitCreation` (49),
  `QRBitstream.parse` (49), `RenderEngine.validate` (41) and `EditorModel.setFrame` (34). Scores
  steer reading only; no finding rests on them.
- Routing (owner rule): package, app-logic and script fixes go to two Codex lanes with disjoint
  files; the main session owns triage, integration, UI and acceptance.
- Bound: one review round, then one rerun after corrections.

### Verdict vocabulary

- **Deterministic defect**: visible in the cited code with a concrete trigger. Closes only with a
  recorded red run on the unfixed code and a green run after the fix.
- **Unreproduced incident**: an observed failure whose cause is not established. Mitigations are
  labeled experimental, with a falsifier and a removal criterion; a later green run is not a cure.
- **Deferred (P3)**: real, without a current trigger or visual-only; recorded as a proposal.

## What the plan review changed

- F-1 is an unreproduced incident; the lock is an experimental mitigation, and the error now
  distinguishes the two nullable AppKit calls so a recurrence is attributable.
- B-1 covers every independently committed edit during a gesture (keyboard nudge as well as
  import), not only imports.
- C-1 must be proven through the actual adapter (suspended discovery, recording event sink, two
  windows of one process), not only through a pure chooser.
- C-2 returns to scope as a SPEC FR-10 violation ("stop immediately on … canceled control").
- A-3 returns to scope: the declared matcher scratch budget is not part of admission (FR-10
  "refuse operations that exceed the declared allocation plan").
- A-2 also validates mapped rectangle corners, not only inverse coefficients.
- B-3 covers automatic batches and uploads; B-4 covers Stop during scroller discovery.
- D-1 reserves the output directory atomically; dry runs use a unique directory.
- D-3 records toolchain provenance and does not qualify reused binaries without it.
- Commits group by violated invariant instead of strictly one per finding.

## Evidence ledger

Each row: observable failure → hypothesis → falsifier → sibling paths → closure. Commit and
log references are filled in as each item closes; red/green logs live under
`.scratch/full-source-review-20261015/` and the lane worktrees, summarized here.

| ID | P | Observable failure | Hypothesis / defect | Falsifier and sibling paths | Closure |
|---|---|---|---|---|---|
| F-1 | P1 | Hosted CI 38652457209 (`setTextAppearance(.monospaced)` false, main actor) and 38795897584 attempt 1 (`unavailableFont(.roundedBoxed)`, off-main export); both reruns green | Concurrent AppKit font matching under heavy load returns nil (unproven). Local: 300 cold processes × 512 concurrent resolutions, 0 failures; hosted run 38821022009 with the stress test, 0 failures but 66 s for 1,920 resolutions (0.24 s locally) | A failure with the lock held falsifies sufficiency; a failure in a serial-only process falsifies the concurrency hypothesis | Stage-specific errors + stress test + experimental process-wide lock. Remove the lock if a locked failure recurs; then move to main-actor pre-resolution with Core Text inputs |
| B-1 | P1 | Import completing during a move/resize drag is dropped | Move/resize replace the whole document from the gesture's `original` snapshot (`EditorModel+Gestures.swift:71-92`) | Siblings: `nudgeSelection` (`EditorModel.swift:502`) and any `edit()` during a gesture | Red/green: import and nudge during move and resize; layer/nudge survive; Undo separates steps |
| C-1 | P1 | One scroll event can be posted to an app the user switched to | `LiveAutoScroll` re-discovers the frontmost window instead of using the frame source's binding (`LiveScrolling.swift:76-140`) | Two windows of one PID; suspended discovery; superseded session | Red/green through the adapter with a recording event sink |
| C-2 | P1 | Cancel during scroll-capture startup can still start a stream | `.starting` stop finishes the source without stopping the producer; preparation reaches `startCapture` (`ScrollFrameSource.swift:125`, `SCStreamFrameProducer.swift:52`) | Cancel during preparation and while the start callback is outstanding | Red/green with a suspending producer double; generation check in the live producer |
| D-1 | P1 | Re-running a tag deletes its archive, dSYMs and DMG before the gate | `rm -rf "$out"` precedes the gate (`release.sh:46-60`) | Concurrent invocations; dry runs | Red/green: sentinels byte-identical; atomic reservation |
| A-2 | P2 | (none observed) Secure mask could skip a layer | `AffineMap.inverted()` returns non-finite coefficients; finite inverses can overflow on corners; `sourceRegions` `continue`s (`Document.swift:295-301`) | Mask duplication reaches the same path (`EditorModel.swift:485`) | Red/green: overflow inverse, overflowing corners and duplication refuse with history unchanged |
| A-3 | P2 | (none observed) Append can exceed the admitted budget | `peakWorkingBytes` omits the declared matcher scratch (`ScrollStitcher.swift:186-210`) | Matcher bookkeeping allocations | Red/green: estimate covers scratch; budget-boundary refusal |
| B-3 | P2 | Closed editor's export keeps running and holds the coordinator | `close()` does not cancel its export (`EditorModel+Export.swift:76-93`) | Upload and automatic batch ownership | Red/green: close during snapshot, upload, batch; other documents unaffected; committed writes reported truthfully |
| B-4 | P2 | Resume after Stop can scroll the target app | `resume()`/`autoStep` ignore `pendingFinish`; `LiveAutoScroll.stop()` cannot stop a discovery in progress | Superseded session; Stop during discovery | Red/green: zero scroll steps after Stop |
| B-5 | P2 | One Undo reverts a colour change and a text edit | `beginEditingText` leaves the continuous adjustment open (`EditorModel+Gestures.swift:403`) | Replacement, deletion, cancel; invalid IDs | Red/green; invalid IDs leave history unchanged |
| D-3 | P2 | E2E evidence from an unreviewed toolchain looks ordinary | `e2e.sh` never runs `doctor.sh`; `--no-build` reuses binaries of unknown provenance | — | Red/green in the script tests; provenance recorded |
| D-4 | P2 | Gate passes with a stale project | Missing XcodeGen exits 0 locally (`check-project-fresh.sh:10-16`) | Release path | Red/green: helper fails; release stops before archiving |
| A-1 | P3 | (none observed) | Block-mean colour signatures miss within-block permutations (`ScrollFrame.swift:82-99`) | Promote if ordinary chart/UI content triggers it | Deferred proposal; counterexample in A-1 report |
| B-2 | P3 | (none) | Caller-task cancellation not propagated into `ExportCoordinator.run` | No caller cancels today | Deferred; specify semantics before a caller relies on it |
| D-2 | P3 | Text looks opaque while editing a translucent annotation | Native editing ignores annotation opacity (`EditorCanvasView.swift:693-740`) | Must keep caret/marked-text usability | Deferred proposal |

## F-1 options

1. **Process-wide lock around the AppKit calls (chosen, experimental).** Smallest change; same
   fonts at every size, same public API and NSFont identity. Weakest assumption: the contention
   is between our own calls, which the lock cannot extend to AppKit's own font work or fontd.
2. **Resolve exact design-and-size fonts on the main actor before dispatching rendering and
   pass Core Text inputs** (Apple documents CTFont/CTFontDescriptor as usable concurrently).
   Strongest rejected alternative: it crosses the Imaging/Features contract and needs metric and
   optical-size parity proof; it becomes the next step if a locked failure recurs.
3. Cache one descriptor per design and derive sizes with `CTFontCreateWithFontDescriptor`.
   Rejected: a descriptor carries its original size's optical attributes.

## Overall approach

- **Chosen: deliver by violated invariant** (gesture/history, scroll lifecycle, privacy geometry
  and bounds, release evidence), with F-1 separate, each group independently reviewable.
- **Rejected premise challenge**: ship only data-loss/privacy/artifact fixes and spend the rest
  on physical qualification. Physical TCC/Spaces/IME/VoiceOver qualification needs the owner's
  hands and desktop, which this task does not authorize; the confirmed P2 defects have concrete
  triggers that synthetic tests can prove.

## Acceptance

- Deterministic defects: a red run on unfixed code and a green run, with zero forbidden sink
  calls asserted (scroll events, clipboard writes, capture starts), Stop/close before and after
  each suspension, and old/new session overlap where relevant. No existing test weakened.
- RED family: overflowing inverse, finite inverse with overflowing corners, mask duplication,
  unchanged history on refusal, and the existing exported-pixel suites stay green.
- Stable gate: `DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer
  RECORTIA_TOOLCHAIN_MODE=stable scripts/check.sh --unsigned` passes.
- Full bilingual native E2E with the same environment prefix
  (`scripts/e2e.sh --lang all --unsigned`, output to a file); record SHA, SDK/build identity,
  scenario count per language.
- Release preservation proven without releasing: sentinel artifacts byte-identical, atomic
  reservation, missing XcodeGen stops before archive work.
- `code-review` (Standards/Spec) on the branch diff, the `reviewer` agent, and a different-model
  `mneves-verify` acceptance; confirmed findings fixed, one rerun.
- Exact-head CI green before the squash merge; main CI watched after it. A recurrence of F-1 on
  main is recorded against the experimental lock, not dismissed as a flake.

## Not in scope

No tag, notarization, release or reinstall (the installed app stays 0.12.0/build19). No website
or app redesign: this repository has no web frontend, and the native UI follows AppKit/SwiftUI
controls per AGENTS.md. Synthetic sinks qualify these race corrections without reading personal
screens; they do not qualify physical capture, accessibility, IME or Spaces behavior.
