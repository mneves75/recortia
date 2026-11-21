# Review list — program 2026-11 (T0)

Status: 2026-11-19, T0 in progress. Sources at `b2726b4` (0.14.0), raw output in `evidence/`:
three Codex Sol defect reviews (`review-*.md`), the Gemini architecture opinion, the modernisation
audit, and the comment audit (`comment-audit.md`). IDs: `R1-` Domain/Imaging, `R2-`
MacPlatform/Features, `R3-` app/scripts/CI, each followed by the reviewer's row ID.

**Rule for "certain".** A row is a certain fix only when the coordinator read the cited lines and
they support the claim, the fix needs no product decision, and a failing-first test can be
written. Every other reviewer row is a *lead*: it enters T1 only through a test that fails on the
current code; a test that cannot fail drops the row. Severities below are the coordinator's.

## 1. Certain fixes (coordinator read the code)

| ID | Sev | Where | Defect | Fix |
|---|---|---|---|---|
| R2-D01 | P1 | `Features/EditorModel+Gestures.swift:110,166` | A click on a selection handle without moving resizes the object: resize stores no grab offset and maps the edge to the pointer (`EditorGeometry.swift:141`). On a secure mask a stationary click 4 pt inside the edge shrinks the mask. | Store the grab offset at `pointerDown`; a release at the grab point is a no-op. RED test on a mask. |
| R3-D03 | P2 | `scripts/check-project-fresh.sh:15` | The freshness gate runs `xcodegen generate` in the worktree, overwriting unstaged project edits, then compares. Observed in the T0 baseline (local XcodeGen 2.48.0 vs 2.46.0). | Generate into a temporary copy and compare; pin XcodeGen in `TOOLCHAIN.json` and check it in doctor. |
| R3-D06 | P2 | `scripts/release.sh:15` | Any first argument other than `--dry-run` (e.g. `--dryrun`) selects the real release path. | Accept no argument or exactly `--dry-run`; reject everything else before preflight. |
| R1-RCI-04 | P2 | `Domain/DocumentSession.swift:42-43,104-106` | `canRedo` is true while an open changed group will commit and clear the redo stack; `canUndo` is true for an untouched group with empty history. | Derive both from whether the open group changed the document. |
| R2-D05 | P1 | `Features/ExportCoordinator.swift:370-379` | Automatic save is skipped silently when its remembered folder no longer resolves (EXP-03 requires a visible failure); a changed preference must stay a silent skip. | Distinguish "folder unreachable" (report `.failed(.accessDenied)`) from "preference changed" (skip). |
| R1-RCI-02 | P2 | `Imaging/RenderEngine.swift:74,190-199` | The base preview's budget adds magnifier scratch it never draws, so a large image with a big magnifier fails its base render. | Count callout scratch only for renders that draw callouts. |
| — | P1 | `.github/workflows/ci.yml:18-22` | Hosted CI red on `main` since 2026-11-11: runner Xcode 27.0 vs the 27.2 baseline; the comment still says 27.0. | Select 27.2 via `DEVELOPER_DIR` after listing the runner's Xcodes; confirm runner OS ≥ 26 before the floor rises. |

Partly refuted: **R2-D07.** The automatic Copy step does recheck its preference before rendering
(`ExportCoordinator.swift:200`, `isAllowed`). What remains is that the upload step can make
authenticated metadata GETs before the final consent guard (P3, security track below).

## 2. Leads that enter T1 only with a failing test

Reviewer marked these read-verified; the coordinator has not yet read them.

- **Editor and model:** R2-D08 (a Text click closes an open colour adjustment — violates the AGENTS.md
  rule "beginning input does not"), R2-D09 (superseded OCR publishes language state), R2-D10 (Fit
  Canvas ignores masks and effects), R2-D11 (hit testing picks a hidden magnifier through an opaque
  mask), R1-RCI-06 (translucent straight arrow double-paints shaft and head), R1-RCI-07 (step numeral
  picks the lower-contrast colour), R1-RCI-12 (rect validation accepts overflowing edges), R2-D15
  (overlay size label vs captured pixels at 2×).
- **Scrolling:** R2-D06 (Stop labels a truncated capture complete), R2-D14 + R3-D08 (Accept before
  the preview is ready; repeated Accept starts repeated assemblies), R2-D16 (wall-clock duration
  limit), R2-D17 (startup producer failure reported as cancellation), R2-D13 (frame queue exceeds
  FR-10's two-viewport budget).
- **App:** R3-D02 (Quit discards a scrolling capture awaiting review without asking), R3-D04 (Cancel
  Export in one editor cancels another's export; scoped cancellation exists at
  `ExportCoordinator.swift:296`), R3-D05 (Save sheet writes JPEG bytes to a `.png` name when the
  format changes while the sheet is open), R3-D16 (an earlier pin notice timer dismisses a newer
  one), R3-D19 (plurals for frames/joins), R2-D18 (Launch at Login keeps a stale failure warning),
  R1-RCI-08 (QR reading-order comparator is not transitive).
- **Gates and scripts:** R3-D07 + R3-D13 (test inventory binds stale runs; a mention counts as
  execution), R3-D12 (E2E provenance omits the foreground helper bundle), R3-D14 (dry-run success
  marker), R3-D15 (space probe exits 0 without a result), R3-D20 (doctor does not check the Swift
  pin).
- **Dead code with zero production callers** (delete with the tests that only exercise them):
  `ImportCoordinator.clearFailure()`, `EditorModel.setRuler(from:to:)`,
  `EditorTool.isSecureRedaction`, `EditorWindowManager.openDocumentIDs` and `model(for:)`,
  `Preferences.launchAtLogin` (old blobs must still decode), `ExportCoordinator.lastOutcome`,
  `EditorEnvironment.input`, `PinsModel.lastInvalidatedCount`, `PendingOffer.resolveCurrent`,
  `ImageStore` single-image accessor, `TextRecognizer.LanguageAvailability`,
  `Annotation.outsetBounds`, `DocumentSession.redoLabel` (and `Entry.label` if nothing else reads
  it), `ObservationLoop.cancel()`, `SystemEventMonitor.stop()`, the unused `remaining` parameter of
  `CaptureUIController.showCountdown`, 3 stale keys in `Localizable.xcstrings`.

## 3. Security track (mneves-security review plus an adversarial fresh-context review)

- R2-D02 (P1): overwriting a file keeps its mode and ACL but not its group, so a `0640` file of
  group A becomes readable by the directory's group B (`MacPlatform/FileSink.swift:270`). Fix
  candidate: `fchown` to the existing group; if that fails, drop group bits (fail closed).
- R2-D03 (inferred): a private destination that disappears and reappears during an overwrite keeps
  the staging file's inherited ACL.
- R2-D04 (inferred): on FAT32/exFAT the no-overwrite fallback can replace a file written between
  the claim and the rename.
- GitHub token shape validated three times (`GitHubUploadSettings.swift:50`,
  `GitHubTokenStore.swift:45`, `GitHubUploader.swift:82-85`): one admission point in the token store.
- R2-D07 remainder: authenticated GETs before the consent guard.
- R3-D11: the Release entitlement checker accepts extra Keychain groups and any team-ID string.

## 4. Decisions for the owner (coordinator's recommendation first)

1. **Reference-app licence.** Its terms (§4, fetched 2026-11-19) forbid reverse engineering. No
   decompilation ran; the static pass read the bundle's metadata, nib strings and filtered binary
   strings. *Recommend:* no decompilation, and future passes limited to metadata, public pages and
   observed behaviour. The 23 new class-A, 5 class-B and 6 class-C capabilities from that pass stay
   out of tracked docs and trains until you rule; the class-B five need your yes anyway.
2. **RecortiaE2E opened from Finder runs live services** (R3-D01, DEBUG only, never shipped).
   *Recommend:* the E2E target refuses to launch without the runner argument.
3. **Discard warning after a successful pin** (R3-D17): the warning says the image was never pinned.
   *Recommend:* say what is lost ("edits that were not copied or saved") on close and quit alike.
4. **Release build in CI** (R3-D09, R3-D10). *Recommend:* add an unsigned Release build of the
   shipping target plus `check-release-binary.sh` to hosted CI, and restrict the E2E foreground
   helper to Debug.
5. **Same-epoch render failure keeps the previous preview** (R2-D12). *Recommend:* show the failure
   over the stale preview and block export until a render succeeds, so the canvas never shows
   pixels the export would not produce.
6. **Inferred imaging and scrolling rows:** R1-RCI-01 (scroll admission threshold uses the frame
   height — a heuristic or a bug, needs a fixture with a short pane), R1-RCI-03/05 (blur sampling
   differs with padding and inside magnifiers; cosmetic effects only), R1-RCI-09 (stationarity
   ignores colour position), R1-RCI-10 (QR ECI declaration), R1-RCI-11 (resized step marker keeps
   its radius), R3-D18 (region release point). *Recommend:* a pixel fixture for each in T4; fix the
   ones it reproduces.
7. **Open questions from the reviews:** late JPEG truncation recovery (R1), cancel during a
   committing sink (R1), single-use import admission (R2), reused window ID during delayed capture
   (R2).

## 5. Architecture: Gemini opinion vs coordinator list (measured)

| Proposal | Measured | Verdict |
|---|---|---|
| Rank 4: non-optional `AppServices`, inline `FeatureModels` | Same as the coordinator's item (21 `features?` sites in `AppModel`, 5 in `SettingsWindowController`). | Adopt (T1b). |
| Rank 5: one presentation function in `AppPresence`, one confirmation builder | Same as the coordinator's item, plus alert unification. `MessagePresenter.present` activates before `SpacePolicy.follow` on the alert. | Adopt (T1b); rerun `window-presence`, `space-policy` and the space probe. |
| Rank 2: 25 protocols → 10 | Every protocol has a test fake, an E2E/preview fake or both; `GitHubCredentialService` exists only for E2E keychain isolation. Merging seams enlarges interfaces. | Reject as stated. Merge only pairs with one adapter and one fake (recognition + QR first). |
| Rank 1: move live adapters into Features, drop wrapper boxes | Features already depends on Imaging and MacPlatform. The E2E fakes it would delete are required by the E2E isolation rule. | Measure the wrapper boxes alone in T1b; keep every fake. |
| Rank 3: Document admission in Domain, one `RevisionedTask`, 10 EditorModel files → 4 | Matches "check data once where it enters" (47 per-method `isFinite` guards). File merging alone changes nothing. | Adopt the admission and the staleness helper in T1b behind T1a's tests; skip the file merge. |

Gemini's line estimates (1.8–2.4k deleted) are unmeasured; each adopted slice reports its actual diff.

## 6. Modernisation (`evidence/modernisation-audit.md`)

Adopt with the floor (T1c): `.macOS(.v26)` and 26.0 in `project.yml`; `ToolbarSpacer`; `Data.span`
/ `mutableSpan` for `RenderRaster` with the RED family and a timing check;
`.strictMemorySafety()` for Imaging and MacPlatform; `.onChange(of:initial:)`. Measure first:
package concurrency flags (`NonisolatedNonsendingByDefault`, `InferIsolatedConformances`) after
confirming every heavy async function is `@concurrent`; `Observations` replacing `ObservationLoop`
(its asynchronous first value can drop the initial render). Not adopted: `SCScreenshotManager`
(`fileURL` writes raw pixels; only HDR to gain). Glass on HUDs, choosers, pins and the drag chip
waits for the editor spike's appearance measurements. **Vision 26 `RecognizeDocumentsRequest` reports
e-mail and phone matches with bounding regions**; the auto-redaction spike measures it as variant C.

## 7. Measure-first performance (from the plan)

Canvas redraws everything on any observed change and fills the checkerboard per 8-pt tile
(`EditorCanvasView.swift:112-125,197,262-280`); OCR and QR re-render the base
(`EditorModel+Recognition.swift:25,108`); each automatic step renders separately
(`ExportCoordinator.swift:184`); bookmark resolution on the main actor three times per batch;
scroll assembly builds a full-size staging array before `Data(pixels)` (`ScrollStitcher.swift:173,337`,
up to 160 MB near 40 MP); `ImageStore` batch lookup scans the store per render; the TIFF-only
pasteboard is read synchronously on the main actor to produce an error (`ImageInput.swift:48`).

## 8. T1 split (0.15 ships as ordered PRs, each merged before the next builds on it)

- **T1a** CI fix and XcodeGen pin; the comment-only commit (line numbers are pinned to `b2726b4`,
  so it lands first); section 1 fixes; section 2 leads that reproduce; dead code.
- **T1b** Architecture slices from section 5, pinned by T1a's tests.
- **T1c** macOS 26 floor (ADR-008), editor refresh from the approved spike, section 6 adoptions.
- **T1d** Automatic redaction (design in `plan.md`; detector chosen from the spike numbers).
- **T1e** A-1 (in progress, timed), A-2, A-9, A-12, A-13 step 1.

## 9. Accepted residuals from the T1a reviews (2026-11-20; owner may overrule)

- **Secure masks.** Moving or growing text or a shape you drew out from under a box reveals what it
  covered (stated in FR-06). Every edit makes the coverage under each box durable, so deleting a
  duplicate under a box, or moving a box over a downscaled image, can leave filled patches outside
  any box. Protection displaced by a layer move has no visible box of its own.
- **Output Preview** is read-only except background, padding, corner radius and shadow.
- **File save, integrity-only volumes** (FAT, exFAT, shares without enforced owners): no
  confidentiality promise; inode reuse on FAT can defeat the folder identity check (R3-07); a crash
  can leave a private staging folder, never swept; a failed save names the file it left. The empty
  private folder and the umask probe are still removed by name after an identity check. The
  two-account exFAT privacy check has not been run. Replace there is a plain rename: a file put at
  the name after the destination was inspected is replaced (1D, declined).
- **File save, folders above the chosen one.** A writer to a parent folder can swap the chosen folder
  between bookmark resolution and the save, redirecting it (1A, R06; declined).
- **File save, overwrite on any volume.** A destination substituted just before the swap leaves the
  snapshot at the name, with the inspected file's access, until the rollback takes it out (1B,
  declined).
- **Auto-redaction detector.** Matches on git remotes and UUIDs are accepted as a precision cost;
  the deadline is still to be measured cold and warm on an idle Mac (T1d).
- **E2E.** The `scrolling` scenario checks the HUD wording through its catalog key: the hosted
  SwiftUI text exposes no accessible value in the test window (cause not investigated).
- **Toolchain.** No macOS 26.0 host verifies launch on the new floor.
- **Scripts review.** F07 and F10 were declined with reasons in the slice's commits.
- **T1b leftovers.** `Entry.label` removal (mechanical, after T1 lands); per-method point guards at
  public entry points stay until admitted point types exist; the presentation-order change needs the
  space probe's `dynamic` mode and the installed-app fullscreen check, both owner-run.
- **T1 review leftovers (2026-11-20).** R-1: T1b's presentation order (Space policy, order front, then
  activate) still needs the space probe's `dynamic` mode and the installed-app fullscreen check, both
  owner-run. R-4: one admission point for the masking-pending guards (T2). R-5: measured and recorded in SPEC §10
  (deadline kept at 8 s; decisions.md).
- **AnnotationRendererTests flake.** One parallel package run failed "drawing twice is
  byte-identical" on the Arabic and emoji sample and passed on rerun and in two full gates; record it
  under the open text-font incident (AGENTS.md F-1) and watch for a recurrence.
- **VoiceOver on Position and Size (2026-11-21).** The native disclosure triangle ignored accessibility
  Press inside the inspector Form, so the section now has a plain header button that reports Expanded or
  Collapsed. Owner-run: open and close it with VoiceOver and reach the four fields.
