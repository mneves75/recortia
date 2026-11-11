# Code review 2026-11 — findings and triage

Owner request (2026-11-10): find what is broken, inconsistent, inefficient or no longer needed; fix
what is certain and list the rest. Target: `main` at `a069cbd`.

## Method and limits

- One read-only reviewer (gpt-6.1-sol through `codex-auto`, no edits, no builds), briefed to cite
  `path:line` for every finding. Scope: defects in the 16 production Swift files changed since the
  2026-10 full-source review (`4845e98..main`); structure across all production Swift; tracked
  non-source files nothing reads. `EditorInspectorView.swift` was excluded because FP-045 rewrites it.
- The main session then read the cited code for every item marked "verified" below. Nothing here
  was reproduced by running the app: no item is closed until its failing test exists.
- Repeated checks were classified before any removal: SHAPE (input validation done twice, a removal
  candidate), STALENESS (identity, revision or consent re-checked after an `await`) and PRIVACY
  (fail-closed redaction or export checks). Only SHAPE is ever removed.

## Defects

| ID | P | Finding | Verified | Disposition |
|---|---|---|---|---|
| R-1 | P2 | Discarding the scrolling review with the Discard button or Escape does not quit when "Keep running in the menu bar" is off. `ScrollUIController.closeReview()` orders the window out (`ScrollUIController.swift:122-126`); `AppPresence` reports a last-window close only from `NSWindow.willCloseNotification` (`AppPresence.swift:45-56`). The close button path does close the window, so the two ways out of the same review behave differently. | Reproduced | Fixed in `1bde99e` (see Resolution). |
| R-2 | P3 | A failed automatic export is always titled "Nothing was exported" (`MessagePresenter.swift:162-164`), also when an earlier step of the same batch succeeded: copy succeeds, save fails, and the alert denies the copy. | Reproduced | Fixed in `51cfdf8` (see Resolution). |
| R-3 | P2 | An automatic batch reads save settings after its copy step has awaited (`ExportCoordinator.swift:337`), so a capture taken while automatic save was off can be saved if the person turns it on, or changes the folder, before the copy finishes. The existing post-render guard compares against the newly read folder, so it does not catch this. | Reproduced | Owner approved 2026-11-10; fixed in `113caf0` and `aaa5a1b` (see Resolution). |
| R-4 | P2 | Overwriting a saved file keeps the old file's mode bits (`FileSink.swift:151`) but not an explicit ACL, because the replacement is a new file renamed into place. | Reproduced (ACL lost) | Owner approved 2026-11-10; fixed in `7883059` (see Resolution). |

## Certain cleanups (no behavior change)

Each was confirmed by search over `RecortiaApp`, `Packages/RecortiaKit` and `RecortiaUITests`.

| ID | What | Where |
|---|---|---|
| C-1 | `CaptureRequest` has no instance anywhere; only its two static delay helpers are used. Keep those, drop the fields, initializer and conformances. | `Domain/Policies.swift:98` |
| C-2 | `MacPlatform.RepeatRegion` is unused; `CaptureCoordinator` has its own private one. | `MacPlatform/DesktopGeometry.swift:127` |
| C-3 | Unused members: `appliesToEveryReference`, `undoLabel`, `QRFixture.isMalformed`, `appKitRect`, `desktopPoint`, `appKitPoint`, `EditorViewport.documentToView`. | `Domain/Document.swift:136`, `Domain/DocumentSession.swift:55`, `RecortiaFixtures/QRFixture.swift:25`, `MacPlatform/DesktopGeometry.swift:24-32`, `Features/EditorViewport.swift:23` |
| C-4 | One-call helpers that hide a single line: `drawBanner`, `beginNewText`. Inline them. | `Capture/RegionOverlay.swift:227`, `Features/EditorModel+Gestures.swift:407` |
| C-5 | `FP-036` has two `status` keys; keep `closed_by_owner`. | `BACKLOG.json:1491` |
| C-6 | The save-folder protocol comment says a stale bookmark resolves to nil; the live implementation resolves and renews it. Correct the comment. | `Features/Services.swift:141` |
| C-7 | SHAPE: export options are validated in the coordinator and again in the pipeline. Keep the pipeline as the one admission point; keep the error mapping. | `Features/ExportCoordinator.swift:166`, `Imaging/ExportPipeline.swift:20,49` |

## For the owner to decide

- **Interface width.** A name search finds about 159 of 875 public names with no use outside their
  module. The reviewer's shortlist of safe candidates (Domain cost and geometry internals, Imaging
  error enums and render limits, MacPlatform auto-scroll policy and seal machinery, Features zoom
  and recognition helpers) removes no lines; it shrinks what the app target can reach. It is
  mechanical and compiler-checked, and tests need `@testable import`. `ArrowLayout`'s path fields
  stay public: `module-contracts.md` promises them. Recommended: do it as one commit per module
  after FP-045, not before.
- **Performance, measure first.** (a) The object list is rebuilt with a linear search per item
  (`EditorModel.swift:362`), quadratic in object count on every committed move. (b) Every draft
  change redraws and re-lays-out all existing text (`EditorCanvasView.swift:114-124`,
  `AnnotationRenderer.swift:71`). (c) Automatic copy and PNG save render the same document twice.
  None was measured; (a) is a simplification worth doing on its own, (b) and (c) add state and need
  a number before they are worth it.
- **Two mappings of import failures** to text, one per string catalog (`MessagePresenter.swift:135`,
  `EditorStrings.swift:234`). Sharing them removes about 15 lines and one translation to maintain.
- **`LiveTextRecognition` and `LiveQRDecoding`** are two forwarding adapters that could be one type.
  Small gain; `AppActions` (one conformer) is worth keeping as a narrow boundary.
- **Token shape validated twice** on one synchronous path (`GitHubUploadSettings.swift:50`,
  `GitHubTokenStore.swift:45`). Removable, but it is a credential path; left alone by default.
- **`docs/handoff/COMPLETE_HANDOFF.md`** (1,984 lines) concatenates superseded root documents and
  no gate reads it. `CLAUDE.md` says not to update `docs/handoff/`, so removal is the owner's call.

## Checked and kept

Staleness checks after awaits (`ExportCoordinator.swift:185,212`), the opaque-mask check at both
admission and render (`DocumentSession.swift:129`, `RenderEngine.swift:120`), the handoff and plan
files that record release evidence, `progress.md`, `tests.json`, `scripts/make-icon.swift`.

## Resolution (FP-046, 2026-11-11)

Owner approval 2026-11-10 ("yes to all"). Branch `fix/review-2026-11`, stacked on
`feat/editor-redesign` at `9bf1159`. Paths are relative to the repository root; the E2E runs are
synthetic and do not qualify TCC, physical Spaces or live alerts.

| ID | Commit | Red (before the fix) | Green (after it) |
|---|---|---|---|
| R-1 | `1bde99e` | `.scratch/logs/r1-red.log`, `.scratch/e2e/20261110-235043-52657`: `last-window` (en) "a confirmed Discard of the last window requests termination: 0 requests" | `.scratch/logs/r1-green.log`, `.scratch/e2e/20261110-235309-82921`: `last-window`, `scrolling`, `scroll-target-binding` pass in en and pt-BR. The scenario presses the real Discard (declined, then confirmed) and Accept buttons; Escape is Discard's keyboard shortcut and runs the same action, so it was not pressed separately. `scrolling`'s stop-count check became relative (`== before + 1`) because the new scenario stops its own sessions first. |
| R-2 | `51cfdf8` | `.scratch/logs/r2-red.log`, `.scratch/e2e/20261110-235629-20710`: every automatic-export alert titled "Nothing was exported" / "Nada foi exportado" | `.scratch/logs/r2-green.log`, `.scratch/e2e/20261110-235702-27980`: `export-feedback-routing` and `automatic-export` pass in en and pt-BR. New title "An automatic export step failed" / "Uma etapa da exportação automática falhou". |
| R-3 | `113caf0`, `aaa5a1b` | `.scratch/logs/r3-red.log`: enabling save and upload mid-copy saved and uploaded; folder A to B saved to B (5 failed expectations). `.scratch/logs/r3b-red.log`: after the freeze, a revoked upload still reached the upload service and a revoked save still rendered (9 failed expectations) | `.scratch/logs/r3b-green.log`: ExportCoordinator, EditorExportLifecycle and EditorIndependentEditSibling suites, 30 tests. `.scratch/logs/r3-e2e.log`: `automatic-export`, `export-sinks` and `stale-folder` pass in both languages; `last-window` and `automatic-save-settings` failed there only at the foreground-readiness control while another app held the foreground; their clean run is pending with the full E2E. |
| R-4 | `7883059` | `.scratch/logs/r4-red.log`: after an overwrite, the ACL set with `chmod +a "everyone allow read"` read back as nil | `.scratch/logs/r4-green.log`: all 9 FileSinkTests pass. A failure to copy the ACL fails the replace and leaves the destination untouched; that path has no dedicated test (no seam forces `acl_set_file` to fail). |
| C-1..C-4, C-6 | `0299da0` | n/a (no behavior change) | `.scratch/logs/cleanup-tests.log`, `.scratch/logs/cleanup-app-build.log`. `module-contracts.md` no longer lists the deleted `appKitRect`. |
| C-5 | `7179b52` | n/a | A duplicate-key scan of `BACKLOG.json` reports none. |
| C-7 | `39d1463` | `.scratch/logs/c7-red.log`, `.scratch/e2e/20261111-002016-99663`: refused options through the live exporter mapped to `.renderFailed` | `.scratch/logs/c7-green.log`, `.scratch/e2e/20261111-002037-5496`, `.scratch/logs/c7-unit.log`. The pipeline is the only admission point; `LiveExporter` maps `invalidOptions` to `.encodeFailed`, the outcome the coordinator returned before. Through the coordinator, invalid options are unreachable (Settings sanitizes scale and quality; pins use scale 1). |
| COMPLETE_HANDOFF.md | `98ed7ec` | n/a | Removed; the remaining mentions are dated records. |
| Object list | `52771fe` | Guard test added first and passing on the old code: `.scratch/logs/i9-guard-before.log` | `.scratch/logs/i9-green.log` (133 editor tests), `.scratch/logs/i9-e2e.log`. No performance claim. |
| Interface width | `1063bfa`, `49131aa`, `e730af9`, `2257fc5`, `dab3b43` | n/a | `.scratch/logs/i10-*.log`; each commit lists what became internal and what stayed public, and why. RecortiaFixtures was not narrowed (not in the brief's module list). |
| Recognition adapters | `5a09346` | n/a | `.scratch/logs/i11-app.log`, `.scratch/logs/i11-e2e.log` (`ocr-qr`, both languages). |
| Import-failure text | done later, `7fbac1d` (FP-045 slice 4) | The alert's wording ("Apenas imagens…") was kept and the editor now uses the alert's detail text. Earlier note: sharing would change visible text: "Only PNG and JPEG images are supported." is "Apenas imagens PNG e JPEG são compatíveis." in `Localizable` and "Só imagens PNG e JPEG são compatíveis." in `Editor`. Needs the owner to choose one wording. | |

Final gates: `.scratch/logs/review-fixes-check.log` (`./init.sh check --unsigned`, "check: all gates
passed"). The full E2E run (54 scenarios, every id in `E2EScenarios.swift` except `capture-focus`
and `editor-presentation`) is **pending a clean run**. The attempt in `.scratch/logs/review-fixes-e2e.log`
(`.scratch/e2e/20261111-004639-68097`: 51/54 en, 50/54 pt-BR) and its reruns are void as evidence,
neither a pass nor a failure: another session was sending real input to the desktop around 00:47,
and the screen was locked from before 01:15 (`IOConsoleLocked`), so foreground-dependent scenarios
could not qualify.

## Second review (2026-11-11)

An independent review of the Resolution found three gaps, all closed test-first on
`feat/editor-redesign`. The E2E runs are synthetic and offscreen; they do not qualify TCC,
physical Spaces or live alerts.

| ID | Finding | Commit | Red (before the fix) | Green (after it) |
|---|---|---|---|---|
| SR-1 (P1) | R-3 still froze the batch inside the coordinator's task, so a main-actor job queued between `handleCapture` and the task (a Settings toggle, a folder choice) joined the batch. | `b91015f` | `.scratch/logs/sr1-unit-red.log`: with `AutomaticExportPlan` in place but still ignored, save turned on later saved, folder A to B saved to B, upload turned on later uploaded (3 tests, 8 issues); the revoked-save guard passed. `.scratch/logs/sr1-e2e-red.log`, `.scratch/e2e/20261111-052755-2255`: on the unchanged code, `automatic-export` turning save on right after `handleCapture` saved a file and rendered twice. | `.scratch/logs/sr1-unit-green.log`: ExportCoordinator, EditorExportLifecycle and EditorIndependentEditSibling suites, 34 tests. `.scratch/logs/sr1-e2e-green.log`, `.scratch/e2e/20261111-053012-40509`: `automatic-export` and `export-sinks` pass in en and pt-BR; `automatic-save-settings` failed there only at the owned-foreground readiness control while the owner used the Mac (pending, not a product result). |
| SR-2 (P2) | R-4's ACL copy could strand the temporary file: an ACL denying delete refuses both the rename and the cleanup `unlink`. | `9a3f09d` | `.scratch/logs/sr2-red.log`: with `<user> deny delete` (control: `rename` onto and `unlink` of such a file both refused), the save threw `accessDenied`, kept the prior bytes, and left `.recortia-<uuid>.tmp`. | `.scratch/logs/sr2-green.log`: all 10 FileSinkTests pass; a failed rename clears the copied ACL before cleanup. |
| SR-3 (P2) | The panel-centring check repeated the sizing and arithmetic itself instead of calling `present`. | `512f654` | `.scratch/logs/sr3-planted-red.log`, `.scratch/e2e/20261111-053313-76687`: with the sizing call removed from `placeNearTop`, `window-chooser` failed on the new check (settled `(900, 678, 420, 248)`, expected centre 900). | `.scratch/logs/sr3-e2e-green.log`, `.scratch/e2e/20261111-053327-80022`: `window-chooser`, `region-overlay`, `countdown` pass in en and pt-BR. `present` now positions through `placeNearTop`, which the scenario calls on a fresh, never-shown panel. |

The SR-1 scenario block restores the save-folder bookmark it found, so `automatic-export` still
ends with the folder state later scenarios saw before. Final runs on the finished tree:
`.scratch/logs/second-review-e2e-final.log`, `.scratch/e2e/20261111-054004-61977`
(`automatic-export` and `window-chooser` pass in en and pt-BR) and
`.scratch/logs/second-review-check.log` (`./init.sh check --unsigned`, "check: all gates passed").
The full E2E run is still pending a clean session.

Noticed then, fixed in `7fbac1d` (FP-045 slice 4): when the editor is open and an automatic batch
has exactly one failure, the editor notice reused `EditorStrings.exportFailure`, whose "Nothing was
exported: ..." texts could also deny an earlier copy in the same batch (the R-2 defect on the
editor route). The notice is now `EditorNotice.automaticExportFailed`, worded like the alert.

## Pre-release security audit (2026-11-11)

Two needs-validation records on the save path, closed test-first in `FileSink.swift`
(`a18d0a5` red tests, `712ebe1` fix), and one finding from a security review of that fix (`c22eed6`
red test, `810085e` fix). Tests use real files in a temporary folder and synthetic data.

| ID | Finding | Change | Red (before the fix) | Green (after it) |
|---|---|---|---|---|
| NV-01 | The temporary file was closed after writing, then `replace` set its mode with `chmod(path)` and its ACL with `acl_set_file(path)`. Another account allowed to rename entries in a shared, non-sticky folder could swap the name for a symlink or hard link to an unrelated file of the person, which then received the destination's access. | `writeNewFile` returns the file's device and inode (`FileIdentity`). `replace` opens the name with `O_NOFOLLOW \| O_NONBLOCK`, requires a regular file with that identity and one link, else fails with EPERM (`accessDenied`) and leaves the destination untouched; mode and ACL go through `fchmod` and `acl_set_fd_np`, and a failed rename clears the ACL through the same descriptor. | `.scratch/logs/nv-red.log`: for both swaps (control: the name resolved to the victim's inode) the save succeeded, the victim went from 0600 to 0644 and gained the destination's ACL, and the destination became the link or took the victim's bytes; a second name on the temporary file was accepted. | `.scratch/logs/nv-green.log`: 14 FileSinkTests pass; both swaps and the second name are refused, the victim and destination are unchanged and no temporary file remains. |
| NV-02 | The temporary file inherited an inheritable folder entry (control: a plainly created file carries `everyone allow read`), so the new bytes were readable by others while written and the entry stayed after replacing a private file. | Inherited entries are removed through the descriptor before the first byte. For a new file (`save` without an existing destination, `saveUnique`) the exact inherited ACL read from the descriptor is restored through it after `fsync`, so the result matches a plainly created file; a replacement keeps none until it gets the replaced file's ACL. | `.scratch/logs/nv-red.log`: the temporary file and the replaced 0600 file carried the entry. The new-save guard passes on the old code and fails, for all three save routes, with the restore disabled (`.scratch/logs/nv-newsave-stripped-red.log`). | `.scratch/logs/nv-green.log`: no entry on the temporary file or the replaced file, mode 0600 kept; new saves carry the same ACL text as the control file. |

| NV-03 (review of `712ebe1`) | A new save's temporary file was created 0644 and written with its inherited entries removed, inherited deny entries included, so others could read bytes being written in a folder whose deny entry keeps them out of every finished file. | Every temporary file is created 0600. For a new file, after `fsync`, the inherited ACL is restored through the descriptor and only then is the descriptor `fchmod`ed to the mode a 0644 creation gets under the umask (best effort: a refusal leaves it owner-only). The umask cannot be read before macOS 27 without a process-wide change, so that mode comes from an empty probe file created and removed in the user's temporary folder; a failing probe fails the save before the temporary file exists. A no-op `afterSync` seam on `POSIXFileSystem` lets the test observe the file between `fsync` and the final access. | `.scratch/logs/nv03-red.log` (`712ebe1` plus the no-op seam): in a folder with inheritable `nobody deny read` and `everyone allow read` entries (control: a file made by the old `open(..., 0644)` call carries both), the temporary file was 0o644 while written, on all three new-save routes. Its final ACL and mode already matched the control. | `.scratch/logs/nv03-green.log` (umask 022) and `.scratch/logs/nv03-green-umask027.log`: 15 FileSinkTests pass; the temporary file is 0600 with no ACL while written, and the new file ends with the control's deny and allow entries and its mode (0644 under umask 022, as before the change). |

Still path-based, and why: reading the destination's mode and ACL, which the design kept. It
copies whatever the destination name yields at that moment onto the new capture, so an account that
can rename entries in the folder can put a more permissive file, or a link to one, at that name and
the capture takes that broader access. NV-01 closed the other direction (the person's other files
can no longer receive the destination's access); this one stays open as an accepted residual. The
rename (a swap after the check can put other bytes at the destination, but never moves the person's
access to another file) and the cleanup `unlink` (it removes a name, not what a link points to) are
safe as they are.

Not closed: inherited entries are in effect from `open` until they are removed a few calls later,
while the file is still empty. By POSIX semantics a descriptor another account opens in that instant
keeps its access to the bytes written afterwards (not probed here: it needs a second account).
Closing it needs a different design, for example creating the file in a private folder. Not proven
by a test: the `ENOTSUP` branches (no ACL-less volume in the suite), the FIFO guard, the failure
paths of `fstat`, `acl_set_fd_np` and the mode probe, and behaviour on volumes other than APFS.
