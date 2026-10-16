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

- F-1 is treated as an incident whose cause is unproven; every mitigation needs a falsifier, and the
  error distinguishes the two nullable font calls so a recurrence is attributable.
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
| F-1 | P1 | Hosted CI 38652457209 (`setTextAppearance(.monospaced)` false, main actor) and 38795897584 attempt 1 (`unavailableFont(.roundedBoxed)`, off-main export); both reruns green | Transient nil from `NSFont(descriptor:size:)` under load (cause unproven). Not reproduced on this host (300 cold processes × 512 resolutions) nor in hosted run 38821022009 (66 s for 1,920 resolutions vs 0.24 s locally); reproduced in the Codex sandbox: E0 1/30 runs, always at `NSFont(descriptor:size:)`, also with a process-wide lock held | The lock was falsified by its own criterion; main-actor pre-resolution was rejected because incident 1 failed on the main actor | Closed (mitigated) with stage-specific errors and a bounded retry: E1 caught a nil that the first repeat recovered; 100 sandboxed runs with the retry saw 3 nils (one on the main thread), all recovered on the first repeat, 0 failures. Root cause remains open |
| B-1 | P1 | Import completing during a move/resize drag is dropped | Move/resize replace the whole document from the gesture's `original` snapshot (`EditorModel+Gestures.swift:71-92`) | Siblings: `nudgeSelection` (`EditorModel.swift:502`) and any `edit()` during a gesture | Closed 60c44ac: red 9 failed expectations (import and nudge during move/resize); green; edits settle the drag via `settleTransformGesture` in `edit()` |
| C-1 | P1 | One scroll event can be posted to an app the user switched to | `LiveAutoScroll` re-discovers the frontmost window instead of using the frame source's binding (`LiveScrolling.swift:76-140`) | Two windows of one PID; suspended discovery; superseded session | Closed f3050d7: red 12 failed checks; bilingual `scroll-target-binding` E2E passes 25 checks with zero events outside the bound window |
| C-2 | P1 | Cancel during scroll-capture startup can still start a stream | `.starting` stop finishes the source without stopping the producer; preparation reaches `startCapture` (`ScrollFrameSource.swift:125`, `SCStreamFrameProducer.swift:52`) | Cancel during preparation and while the start callback is outstanding | Closed f3050d7: red showed a capture start after Stop; green for cancel during preparation and during the start callback |
| D-1 | P1 | Re-running a tag deletes its archive, dSYMs and DMG before the gate | `rm -rf "$out"` precedes the gate (`release.sh:46-60`) | Concurrent invocations; dry runs | Closed d1b9915: red deleted retained artifacts; green keeps sentinels byte-identical, refuses a held reservation, dry runs use unique directories |
| A-2 | P2 | (none observed) Secure mask could skip a layer | `AffineMap.inverted()` returns non-finite coefficients; finite inverses can overflow on corners; `sourceRegions` `continue`s (`Document.swift:295-301`) | Mask duplication reaches the same path (`EditorModel.swift:485`) | Closed 2dc33db: red inverse `tx: -inf` and mask admission changed history; green refuses with history unchanged, including duplication |
| A-3 | P2 | (none observed) Append can exceed the admitted budget | `peakWorkingBytes` omits the declared matcher scratch (`ScrollStitcher.swift:186-210`) | Matcher bookkeeping allocations | Closed 2dc33db: red reached pixel comparisons under a budget without bookkeeping; green refuses before matching, exact peak admits |
| B-3 | P2 | Closed editor's export keeps running and holds the coordinator | `close()` does not cancel its export (`EditorModel+Export.swift:76-93`) | Upload and automatic batch ownership | Closed c8c6359: red 10 issues (no cancellation, wrong committed outcomes); green 5 tests incl. other-document control |
| B-4 | P2 | Resume after Stop can scroll the target app | `resume()`/`autoStep` ignore `pendingFinish`; `LiveAutoScroll.stop()` cannot stop a discovery in progress | Superseded session; Stop during discovery | Closed c8c6359 (model) and f3050d7 (adapter): red 7 issues and adapter red; green zero steps/events after Stop |
| B-5 | P2 | One Undo reverts a colour change and a text edit | `beginEditingText` leaves the continuous adjustment open (`EditorModel+Gestures.swift:403`) | Replacement, deletion, cancel; invalid IDs | Closed 60c44ac + correction f4821a6: red 6 issues; the first fix broke two contract tests (4 issues), corrected to close the adjustment on commit only |
| D-3 | P2 | E2E evidence from an unreviewed toolchain looks ordinary | `e2e.sh` never runs `doctor.sh`; `--no-build` reuses binaries of unknown provenance | — | Closed d1b9915 + 4927938, reopened by reviewer R-1 (check.sh rebuilds the same binary) and closed again in cycle 2 with an app-bundle SHA-256: red built with an unreviewed toolchain, reused a stale binary after an edit, and launched a replaced binary; green refuses all three |
| D-4 | P2 | Gate passes with a stale project | Missing XcodeGen exits 0 locally (`check-project-fresh.sh:10-16`) | Release path | Closed d1b9915: red passed without XcodeGen and reached archive work; green fails before archiving |
| A-1 | P3 | (none observed) | Block-mean colour signatures miss within-block permutations (`ScrollFrame.swift:82-99`) | Promote if ordinary chart/UI content triggers it | Deferred proposal; counterexample in A-1 report |
| B-2 | P3 | (none) | Caller-task cancellation not propagated into `ExportCoordinator.run` | No caller cancels today | Deferred; specify semantics before a caller relies on it |
| D-2 | P3 | Text looks opaque while editing a translucent annotation | Native editing ignores annotation opacity (`EditorCanvasView.swift:693-740`) | Must keep caret/marked-text usability | Deferred proposal |

## F-1 options

1. **Process-wide lock around the font calls (tried, falsified).** The sandbox reproduced the
   nil with the lock held, so contention between our own calls is not the mechanism.
2. **Main-actor pre-resolution with Core Text inputs (rejected).** CI incident 1 failed on the
   main actor and a sandbox nil also occurred there, so moving the call would only move the
   failure; it would also cross the Imaging/Features contract.
3. **Cache resolved fonts (rejected).** `CTFont`/`NSFont` are not Sendable in this SDK, so a
   shared cache needs an `@unchecked` or `nonisolated(unsafe)` escape that AGENTS.md forbids.
4. **Bounded retry of the same call (chosen).** Same APIs, sizes and font identity; failures
   stay typed and attributable. Measured: every observed nil recovered on the first repeat.
   Strongest rejected alternative: a Core Text fallback (`CTFontCreateWithFontDescriptor`),
   which returned the right font in the sandbox but never returns nil, so a wrong-font fallback
   could pass silently.

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
  main is recorded against the bounded retry, not dismissed as a flake.

## Two-axis code review (cycle 1 of at most 2)

`code-review` on `5268d48...7aedad9`, Standards and Spec in separate fresh contexts, with
`cccc 1.8.0` over the 13 changed production files (377 functions; 34 parse errors in
ExportCoordinator, SCStreamFrameProducer and LiveScrolling, so their metrics are partial; no new
hotspot). No hard standards violation. Accepted and fixed in the final batch:

- Spec 1: an import completing during an open colour adjustment, and a new-text commit, joined the
  "Adjust" undo step (same invariant as B-1/B-5).
- Spec 2 / Standards 8: the E2E fingerprint hashed untracked file names, not contents; SDK identity
  was not recorded.
- Spec 4: `LiveAutoScroll` and `LiveScrollTargetChecker` chose "the window at the centre" with
  different layer filters, so a floating window made every step refuse; both now share one
  selection. Standards 7: the single-first-step assumption is documented.
- Spec 5: a refused or no-op edit settled an active drag; only a changing edit settles it now.
- Standards 2: the scroll budget repeated matcher limits as literals; it is derived from the
  named constants. Standards 3: `settleTransformGesture` switches exhaustively.

Disproved or left as is: the `try?` → `.targetLost` mapping in `LiveAutoScroll` predates this
change and `.targetLost` is the honest outcome; naming/duplication preferences (one-way
`generation`, `startupID`, `documentID: exportID`, repeated guards) carry no defect; the stress
test landing before its fix is intended (it exists to detect F-1 recurrences).

## Independent reviewer (cycle 2)

The `reviewer` agent wrote 12 requirement-derived tests on 0ab32d9 (Swift and Python), proved
them with mutations (dropping the drag settle, reverting close to drag-only invalidation,
removing the post-start stop and startup guard, removing corner validation, restoring the old
release deletion), and found two defects:

- R-1 (P2, reopens D-3): `check.sh` rebuilds the same `RecortiaE2E` binary in `.build/dd`
  without touching the E2E provenance, so `e2e.sh --no-build` could run a binary its provenance
  does not describe. Fixed by recording and verifying a hash of the built app bundle.
- R-2 (P3, pre-existing, same invariant as B-1/B-5): nudge, delete, duplicate, arrange and crop
  joined an open colour adjustment. Fixed by having each independent command close the
  adjustment, as imports and text commits do; closing it inside `edit()` was rejected because
  the reviewer's mutation showed it breaks restyle coalescing.

Cycle-2 evidence (Codex lane, then the coordinator outside the sandbox): R-1 red showed a
replaced binary launching under matching provenance; green refuses a replaced executable, changed
resource content, renames, additions, deletions and symlink-target changes before launch. R-2
was extended to every independent command found: nudge, delete, duplicate, z-order, crop and
Reset Crop, renumber steps, transparency comparison, side by side, fit and expand canvas, and
alignment; all 12 cases failed first with 24 issues and now pass, as do the colour-coalescing
control and the existing history tests. Logs:
`.scratch/full-source-review-20261015/cycle2-evidence/`.

Two read-only observations without a demonstrating test are recorded as FP-036 proposals:
closing a pin does not cancel its snapshot (the coordinator stays busy until it finishes), and a
Pause (not Stop) during the first automatic step's window discovery can still post one scroll.

## Independent verification, pass 2 (002f8b8)

PASS on all seven frozen criteria from gpt-6-astra, a model that built nothing, confirmed from
its own Codex session record; see [acceptance-verdict.md](acceptance-verdict.md). It re-ran 689
tests and seven single-fix revert controls (including D-3), checked font parity against the
baseline, and audited the native E2E and stable-gate artifacts it could not drive in its sandbox
(recomputed app-bundle SHA-256 matched the provenance).

## Final candidate gates (002f8b8)

- `scripts/check.sh --unsigned`, stable Xcode 27.0 (27A266a), on dd3d515 (002f8b8 differs only
  by documentation and one Swift comment, lint-checked): exit 0; 720 package tests (139
  MacPlatform, 174 Imaging, 343 Features, 64 Domain); 617 translated strings; both builds.
- Hosted CI on the exact head 002f8b8: run 38842296882, success.
- Full bilingual native E2E on 002f8b8, unlocked console idle 152 s
  (`.scratch/e2e/20261015-235920-72780`): 48/48 scenarios per language, 2,247 assertions and
  138 screenshots each, exit 0, including `capture-focus`, `editor-presentation` and the new
  `scroll-target-binding`. Provenance: git 002f8b8, stable mode, SDK 27.0 (26A425), app-bundle
  SHA-256 2cb9b690…70ff6.

## Independent verification, pass 1 (0ab32d9)

A fresh-context verifier ran the frozen criteria on 0ab32d9: the stable gate (710 tests), hosted
CI, three full bilingual E2E runs plus focused and main-branch controls, and ten single-fix
reverts (D-1, D-3, D-4, B-1, B-3, B-4, B-5, A-2, C-2, A-3), each red when reverted and green when
restored. Verdict FAIL, and not independent enough: the requested different model did not take
effect, so it ran as the same model as the main session. Findings mapped:

- D-3 binary provenance (same as reviewer R-1): fixed in 1110c9e (app-bundle SHA-256).
- Docs: wrong proposal count, missing gate results at 0ab32d9, and an F-1 "no longer fail"
  overclaim: fixed in the CHANGELOG and this plan.
- A new `try?` in `SCStreamFrameProducer`'s superseded-stream cleanup: the ignored error is now
  justified in place (handlers detached, stream released, the caller still gets `.canceled`),
  matching the existing documented call in `stop()`.
- E2E: every scenario passed in at least one branch run; the intermittent `capture-focus` /
  `editor-presentation` readiness failures coincided with the console locked or the user active.
  The final run is taken on an unlocked, idle console. A second verification pass on the final
  candidate must use a model other than the main session's.

## Gate results on the candidate (0ab32d9)

- `scripts/check.sh --unsigned` with Xcode 27.0 (27A266a) in stable mode: exit 0. Package tests
  137 MacPlatform + 174 Imaging + 335 Features + 64 Domain = 710; strict format lint; project
  freshness; app and E2E target builds; 617 strings with pt-BR translations.
- Hosted CI on the exact head: run 38835156965, success.
- Full bilingual native E2E (`.scratch/e2e/20261015-223003-83183`): 46/48 per language, 136
  screenshots each. `capture-focus` and `editor-presentation` failed their owned-foreground
  readiness control (fixture never key/active/foreground) while the console was locked
  (`IOConsoleLocked` true, about 64 minutes idle). The same two passed in the unchanged
  baseline run earlier that evening (47/47). Per AGENTS.md this is a failed readiness control,
  not a product diagnosis; both are rerun on an unlocked, idle console before merging.

## Process notes

- Codex's workspace-write sandbox keeps `.git` read-only, refuses SwiftPM's nested
  `sandbox-exec` (use `--disable-sandbox`, which affects only SwiftPM's own sandbox) and makes
  pasteboard, OCR and QR rendering tests fail for environmental reasons. Lanes therefore stopped
  at each group, and the main session reviewed, committed and ran the full suite outside it.
- A focused green is not enough: the first B-5 fix passed its own tests but broke two existing
  contract tests that only the full suite exercised. Every group now closes on the full suite.
- The same sandbox reproduced F-1's failure class (see below), which the coordinator's host and
  one hosted stress run had not.

## Not in scope

No tag, notarization, release or reinstall (the installed app stays 0.12.0/build19). No website
or app redesign: this repository has no web frontend, and the native UI follows AppKit/SwiftUI
controls per AGENTS.md. Synthetic sinks qualify these race corrections without reading personal
screens; they do not qualify physical capture, accessibility, IME or Spaces behavior.
