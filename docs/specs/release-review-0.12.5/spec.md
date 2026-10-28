# 0.12.5 — instrumented review and corrective release

Written 2026-10-28 against `3d52b80` on branch `chore/toolchain-27.2-and-release-review`.
Scope authority: owner request of 2026-10-28 ("review and update this project", fix problems,
bump, document, commit, push, merge). No publishing, no store submission, no credential change.

## Why this exists

Three independent read-only reviews ran against the same tree: macOS design and accessibility,
architecture and performance, and test quality. Each returned "no P0, with notes". The reviews
themselves are not the deliverable. The deliverable is a smaller set of changes where every claim
is either (a) a defect whose mechanism is quoted from source, or (b) an instrument that can fail.

The two reviews share one structural finding, and it is the reason this release exists:

> The repository has instruments for behaviour and none for rendered output. `E2ESnapshot.park`
> forces `.aqua` and `E2ESnapshot.host` injects `colorScheme: .light`
> (`RecortiaApp/E2E/E2ESnapshot.swift:20-26`). Dark appearance, Increase Contrast, and non-default
> accents are therefore unobservable by construction. A defect that only appears on dark content
> survived 683 package tests and 47 bilingual scenarios.

A second structural finding is about the gate itself: on 2026-10-28 every gate aborted inside
`scripts/doctor.sh` because `TOOLCHAIN.json` recorded Xcode 27.1 (27A9275) while the host had been
updated to 27.2 (27B48). The record was duplicated as a literal in `scripts/test-doctor.py`, so
updating it correctly then broke the test. The instrument could not report the truth about itself.

## Falsifiers

This spec is wrong if any of these hold after implementation:

1. `scripts/check.sh --unsigned` passes without the new controls actually executing (proved by
   planting a violation and watching the gate fail).
2. The appearance snapshots pass while the seam markers remain invisible on dark content (proved
   by a pixel assertion with a documented contrast threshold, and by a control that fails when the
   dual stroke is reverted).
3. A UI fix lands with no test that fails when the fix is reverted.

## Verified findings

Verified means: the cited line was read directly, not taken from a reviewer's report.

| ID | Claim | Evidence I read | User harm |
|---|---|---|---|
| V1 | "Remove destination and token" deletes the Keychain credential in one click, with no `role: .destructive` and no confirmation | `RecortiaApp/Settings/GitHubUploadSettings.swift:117` vs the enable path's `confirmationDialog` at `:141` | Irreversible loss of a credential the app cannot recover |
| V2 | The scrolling review window is `[.titled]` only, and Escape is wired to `Discard` | `RecortiaApp/Scroll/ScrollUIController.swift:93`; `RecortiaApp/Scroll/ScrollViews.swift:187-188` | A multi-frame stitch is destroyed by the habitual "get me out" key, with no close button and no ⌘W |
| V3 | Seam markers use `Color.primary`, one colour over arbitrary screenshot pixels | `RecortiaApp/Scroll/ScrollViews.swift:202-213` | The only marks the review asks the user to check are invisible on dark pages |
| V4 | The pin's image is `Image(decorative:)` and then labelled, so the label is dead | `RecortiaApp/Pins/PinPanels.swift:142-147`; the working sibling at `ScrollViews.swift:163-169` | VoiceOver users cannot reach pinned content at all |
| V5 | The save-folder row is a hand-built `HStack` with an untruncated, unhelp-tagged value | `RecortiaApp/Settings/SettingsView.swift:154-160` | Long or pt-BR folder names wrap the row and push the control off the trailing edge |
| V6 | The E2E isolation scanner matches one spelling per rule | `scripts/test-e2e-isolation.py:18-36` (`\bUserDefaults\s*\.\s*standard\b`, `\bNSPasteboard\s*\.\s*general\b`) | `UserDefaults(suiteName:)` and `NSPasteboard(name: .general)` reach the user's real defaults and clipboard while the scan reports clean |
| V7 | The defaults-domain guard test can be satisfied by a comment | `scripts/test-e2e-isolation.py:103-106`: `str.index` does not skip `//` lines, while `scan()` at `:53` does | The control that protects the real preferences domain cannot fail |
| V8 | Two entitlements tests submit the same plist and assert the same result | `scripts/test-release-entitlements.py:27` and `:58` | Duplicate coverage, which the repository's own test standard bans |
| V9 | `PinsExportTests` names three sources in its title and exercises one | `Packages/RecortiaKit/Tests/FeaturesTests/PinsExportTests.swift:82` (`arguments: ["closeAll"]`) with a body switching on `"close"`/`"invalidate"` | Two revocation paths are unasserted |

Rejected as findings on inspection: the editor's destructive confirmations, the quit
confirmation, canvas scrims over user content, the `.accessibilityElement()` usage in the scroll
preview, and pt-BR coverage of sampled keys. Those are correct and are recorded here so a later
review does not re-audit them.

## Decisions

**D1 — The appearance axis is a scenario, not a global switch.** Changing `E2ESnapshot` defaults to
render everything twice would double every scenario's runtime and make 47 reports ambiguous.
Instead: `park`/`host` gain an explicit `appearance:` parameter defaulting to the current light
behaviour, and one new scenario renders the surfaces where user content sits under app chrome (the
scroll review and the editor canvas) in dark, asserting pixels. Rejected alternative: a
`RECORTIA_E2E_APPEARANCE` environment variable driving the whole runner — hidden global state, and
the report would not say which appearance produced a given screenshot.

**D2 — Destructive discard asks, then discards.** The review window becomes `.closable`, and the
close button, Escape, and the Discard button all route through one confirmation. Escape still
resolves the window (HIG), but it no longer destroys a stitch silently. Rejected alternative:
closing hides the review and keeps the session alive for later — there is no user path back into a
`.reviewing` session once its window is gone (`ScrollUIController.render` only presents the review
from an observed state change), so that design would strand the capture, which is worse.

**D3 — `tests.json` is generated, never hand-written.** A hand-maintained third status file is the
exact failure this release exists to correct. `scripts/tests-report.py` writes it from the real
suite inventory plus the local evidence it can see, labels every status as a local observation with
its evidence path, and `--check` fails when the inventory names a suite whose command or evidence
contract no longer exists. Rejected alternative: extend `BACKLOG.json` — it is a task contract, not
a test inventory, and mixing the two is how 97 KB became untrustworthy.

**D4 — One entry point, no wrapper layer.** `./init.sh` resolves the installed toolchain against
`TOOLCHAIN.json` and then execs an existing suite. It exists because four separate invocations in
this session needed the same `DEVELOPER_DIR`/`RECORTIA_TOOLCHAIN_MODE` boilerplate to be typed
correctly, and getting it wrong silently blocks every gate. It adds no build logic of its own.

## Work items

Each item lands with a test that fails when the item is reverted. `check` means
`./init.sh check`, `e2e` means `./init.sh e2e --lang all`.

| ID | Work | Acceptance |
|---|---|---|
| W1 | Derive the doctor fixture's toolchain from `TOOLCHAIN.json`; record Xcode 27.2 (27B48) as the development toolchain with primary evidence | `scripts/test-doctor.py` passes and fails if the record and the fixture disagree; `doctor.sh` passes in development mode and still refuses release mode |
| W2 | Isolation scanner: add `UserDefaults(suiteName:)` and `NSPasteboard(name:/Name. general)` rules, each with a planted control | The planted-violation test fails if either rule is removed |
| W3 | Defaults-domain guard test skips comment lines | Removing the real guard while leaving its text in a comment fails the test |
| W4 | Remove the duplicated entitlements test | Suite still covers every failing shape |
| W5 | Pins revocation table exercises `close`, `invalidate`, `closeAll` | Dropping `PinsModel.invalidate`'s revocation fails |
| W6 | Appearance axis in `E2ESnapshot` plus a dark-content scenario asserting seam-marker contrast | Reverting the dual stroke fails the scenario |
| W7 | Seam markers use an opaque under-stroke plus accent over-stroke, as the canvas already does | W6 |
| W8 | Pin image becomes a real accessibility element with its label | Source: the label is applied to an element, not to `Image(decorative:)`. The VoiceOver-tree assertion is deferred; see the amendment below |
| W9 | Save-folder row becomes `LabeledContent` with one-line truncation and a help tooltip | Source: one-line truncation, middle truncation and a help tooltip on the value, control on the trailing edge. The rendered single-line-height assertion is deferred with W8 |
| W10 | "Remove destination and token" is destructive and confirmed, with new pt-BR strings | `check` passes and the localization gate covers the new keys |
| W11 | Scroll review window is closable; close, Escape, and Discard ask one confirmation | The window is closable, the controller is its delegate, the question is asked exactly once, a declined answer keeps the window open and a confirmed one closes it; on a live `.reviewing` session a declined discard leaves the stitch in place |
| W12 | `scripts/tests-report.py`, `tests.json`, `./init.sh`, `progress.md` | `--check` fails on a stale inventory; `./init.sh check` runs the gate |

## Amendments, 2026-10-28 after the adversarial review

Two acceptance criteria promised proofs this repository cannot produce yet. Making them true would
have meant inventing a result, so they are corrected here and the gap is a ticket, not a claim.

- **W8, pin accessibility, and W9, folder row.** Both were written to be proved by rendering.
  Measured, not assumed: a hosted `NSHostingView` exposes an empty accessibility tree in-process
  (`root.accessibilityChildren()` returns nothing for the pin's hosted view when no accessibility
  client is attached), and the existing `E2EAccessibilityControl` reaches only native AppKit
  controls, not SwiftUI surfaces. A rendered-height comparison for W9 would need a resolvable save
  folder bookmark and a layout assertion instrument that does not exist here. The fixes stay, with
  source-level acceptance; the instrument is the first ticket of the next unit.
- **W11.** The live half of the criterion now runs in the `scrolling` scenario, where the model is
  actually in `.reviewing`: a declined discard must leave the stitch intact. The confirmed half is
  proved in `appearance-contrast` by the window decision, because the only other caller of
  `model.discard()` in that path is the gate itself.

## Deferred, with reasons

- **Editor commands in the menu bar** (report finding 1: ⌘C/⌘S/⌘Z die when the canvas is not first
  responder). Real and P1, but the obvious fix is wrong: a global ⌘C item would take Copy away from
  text annotation editing. The correct shape routes Copy through the responder chain and validates
  Save/Undo against a text-editing first responder. That needs its own spec, its own E2E
  (`focus a text annotation, press ⌘S`), and physical keyboard qualification. Recorded as the first
  ticket for the next work unit.
- **Plural variations for `%lld frames` and `%lld joins`** (finding 6). Correct, but both catalogs
  need `plural` variations in two languages and the localization gate has no coverage of the plural
  branch (`scripts/test-localization.py` only emits plain `stringUnit` fixtures). Instrument first,
  then strings.
- **4 pt grid alignment of the editor bars** (finding 8). Needs a geometry assertion instrument
  before a cosmetic change; without one, the change is unverifiable beyond eyeballing.
- **Text-layout memoisation, AX messaging timeout, retained-pixel budget for editors** (architecture
  findings F1–F3). Each needs a measurement on a stable-OS host. This host is macOS 27.2 GM with a
  release-candidate toolchain, so performance claims here would not qualify (`SPEC.md` §10).
- **`release.sh` wiring for the bundled-license test** (test finding 6). Owner-only path; changing it
  requires its own planted-violation controls and a dry run.
- **FP-041** stays deferred by the owner's 2026-10-19 decision.

## Evidence to produce

1. `.scratch/logs/check-*.log` ending in `check: all gates passed`, with the doctor line naming the
   development toolchain.
2. `.scratch/logs/e2e-*.log` plus per-language `report.json` where every scenario passed and the new
   appearance scenario carries a pixel assertion.
3. Plants: the isolation rules, the guard test, the seam contrast, and the discard confirmation each
   fail on a deliberate revert, recorded in `progress.md`.
4. An independent adversarial review of this diff by an agent that did not write it, and a
   `mneves-verify` pass over the fixed SHA.
