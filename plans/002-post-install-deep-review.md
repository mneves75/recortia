# Post-install branch deep review: non-focus surfaces

## Status and decision

- **Disposition:** advisory audit complete; zero confirmed residual fix plans in the bounded surfaces below.
- **Planned at:** `0781aedcbf4e743fd25b87b71356cbb5391aa86b`, 2026-10-15.
- **Branch:** `feat/onboarding-feature-guide`.
- **Fixed comparison base:** `origin/main` at `53c4d8192d4f05e90576bfa8608f0a7b668d3e3f`.
- **Mode:** improve deep branch; read-only source review, with this plan as the only output.
- **Dependencies:** none for this disposition. Capture-focus and editor-presentation diagnosis belongs to the main investigation and is deliberately excluded here.
- **Execution:** there is no implementation ticket in this document. Do not manufacture changes to obtain a nonempty findings list.

The original broad diff contains 119 files and roughly ten thousand changed lines. This is a bounded deep review of the selected non-focus seams, their directly inspected callers and relevant tests, not an assertion that every hunk or runtime path was independently qualified. No source, settings, installed application, credentials, screenshots or user data were changed or accessed by this audit.

## What the review changed

The earlier `plans/feature-discovery-deep-review.md` mixes then-current findings with future feature direction. Several concrete concerns are now implemented and reviewed: safe sharing copy, explicit line support, saved colors, bounded area sampling, text appearance/decorations and curved arrows. Treat that document as historical advisory input reconciled against the current specs and evidence, not a current list of missing implementations. No new source correction survived this review's confirmation threshold.

The installed 0.12.0/build19 local-test candidate and the stable signed gate do not erase the two known native focus/presentation failures. Conversely, those failures do not establish a new defect in the unrelated palette, sampling or annotation changes. This document creates no release or full-parity claim.

## Scope and methods

Read `improve/SKILL.md`, all audit-playbook categories including Finding format, and the plan template. Inspected the changed-file inventory against the fixed base, root instructions and selected spec/module/ADR sections, the previous deep-review plan, feature specs, and previous correction evidence.

The substantive source reads covered:

| Surface | Source and directly inspected seams | Assessment |
|---|---|---|
| Sampling and privacy | `EditorModel+PixelTools.swift`, `PixelSampler.swift`, `EditorModel.swift` edit invalidation, `EditorModel+Preview.swift`, close invalidation in `EditorModel+Export.swift` | Bounded 1/3/5-pixel neighborhoods, current sanitized base, operation identity, cancellation and explicit text copy are represented. No confirmed new stale-result or raw-image sink bypass found. |
| Saved palette and preferences | `SavedAnnotationPalette.swift`, `EditorModel+Palette.swift`, `SettingsStore.swift`, `EditorInspectorView.swift`, `EditorPaletteTests.swift` | Explicit stroke-only storage, twelve-color limit, opaque deduplication, protected future-schema refusal, closed-editor refusal and separate undo action are represented. |
| Curved arrows, lines and history | `Annotation.swift`, `ArrowCurve.swift`, `ArrowLayout.swift`, `EditorGeometry.swift`, `EditorModel+ArrowCurve.swift`, `EditorModel+Gestures.swift`, frame/translation/edit helpers in `EditorModel.swift`, `DocumentSession.swift`, `EditorCurvedArrowTests.swift` | Reviewed endpoint/control transport, admission before mutation, lazy gesture grouping, segment frame resizing and shared painted geometry. Previously corrected admission cases remain historical findings. |
| Text appearance and decoration | `TextLayout.swift`, `AnnotationRenderer.swift`, `EditorCanvasRenderer.swift`, `EditorModel+TextAppearance.swift`, text begin/commit in `EditorModel+Gestures.swift`, `EditorCanvasView.swift`, `EditorTextDecorationView.swift`, inspector background controls | Shared native font/layout, explicit render failure, native clipping/input transport and selected boxed-fill controls are present. No additional confirmed source defect found. |
| Tour and documentation truthfulness | `OnboardingModel.swift`, `OnboardingView.swift`, README validation sections, SPEC privacy/export geometry sections, feature specs, previous review evidence | Tour now explicitly explains pre-redaction automatic exports and irreversibility; replay and completion remain separate. Historical evidence is not treated as current runtime proof. |
| Toolchain and delivery tooling | Branch diff of `doctor.sh`, `release.sh`, CI and `TOOLCHAIN.json`, full `doctor.sh`, ADR-001 sections | Stable/development channels are separated; release doctor forces stable mode. No newly demonstrated release-policy bypass found. |

Correctness, security/export, test adequacy, architecture/complexity, tooling and docs received source review. Performance was considered only as a source-risk screen: no timings or profiles ran. No dependency was added by these reviewed feature slices; a fresh vulnerability audit was not run. Direction remains in the existing approved specs/reference matrix; this audit does not add a new feature roadmap.

## Confirmed residual findings

| Origin | Finding | Priority | Evidence | Fix plan |
|---|---|---|---|---|
| Introduced | None confirmed within this bounded audit | — | Source review only; limits below apply | None |
| Pre-existing in touched surfaces | None newly confirmed and actionable within this audit | — | Known deferred/physical limitations retained separately | None |

Absence of a confirmed finding is not proof of absence of bugs. In particular, native text composition, physical input, framework geometry resource usage and display/Space behavior cannot be established by this read-only review.

## Considered and rejected

1. **Automatic exports happen before redaction: current tour omits the hazard.** Fixed independently. `OnboardingView.swift:220-228` now instructs users to disable copy/save/upload before sensitive capture and says later edits cannot recall earlier copies. The old FD-01 text is stale as a current finding. The timing itself is an approved opt-in behavior, not a new upload authorization or a request to replace the architecture.
2. **Area picks can publish after a new document revision, sample-size change, replacement pick or close.** Not supported by the inspected current code: `EditorModel+PixelTools.swift:87-112` checks request token, full document identity, base key/image identity, cancellation, close and sample size; `EditorModel.swift:250-253` invalidates picks on edits, and close also invalidates. Sampling the sanitized base rather than annotations is explicit in `docs/specs/area-color-sampling/spec.md`; do not change that product contract.
3. **A saved swatch can end an adjustment despite refusal, or overwrite protected preferences.** Fixed/guarded. `EditorModel+Palette.swift:32-45` admits membership/schema/close before ending the adjustment. `EditorPaletteTests.swift` already covers independent undo, denied apply, future schema, duplicate/full saves and closed actions. This is not a reason to add a new palette store or preference migration.
4. **Curve creation, endpoint drags, canvas shifts, frame edits and duplication mutate history before admission.** Previous confirmed corrections, not fresh residual findings. Current gesture code admits a changed document before `replaceDocumentInGesture`; creation validates before ending the previous adjustment; current frame and translation helpers validate. `docs/specs/curved-arrows/review-evidence.md` records the five corrections and their distinct red/green evidence, including the tiny-curve duplicate fixture. Preserve that evidence rather than write duplicate work.
5. **Boxed backgrounds reset or display the future default instead of selected fills; native wrapped text/marked suffix remains stale at zoom.** These were previously confirmed issues and received targeted corrections and evidence. Current inspector derives selected boxed fills, identifies mixed backgrounds and enables Reset for selected explicit fills; current native canvas uses the fixed text engine/font presentation path. See `docs/specs/text-appearance/decoration-review-evidence.md`. Runtime requalification is separate; source review must not relabel the old failure as still reproduced.
6. **Curve layout's finite extreme coordinates guarantee acceptable Core Graphics memory/time.** Unconfirmed hypothesis. Bounded root-search iterations do not bound framework stroking/union costs. The prior curve review already records this exact uncertainty. No measured failure or approved new global coordinate cap exists here; do not implement a speculative cap/cache or call the hypothesis confirmed.
7. **Replace the editor/controller or cache text/curve layouts because the code is large.** No observed incorrect result or measured workload justifies that change. Stateless operation-local geometry and the current domain/Imaging boundary are explicit decisions. Complexity alone does not prove a beneficial refactor.

## Alternatives and five-year check

**Chosen:** stop this non-focus audit at zero residual fixes and continue the separately owned, evidenced focus/presentation diagnosis. This has the smallest review surface and avoids reopening accepted corrections without a reproducible trigger.

**Alternative:** immediately add more reference-product features or refactor annotation machinery. The reference matrix contains real unfinished direction, but feature-count expansion does not repair a demonstrated residual here, and a generic path/layout architecture would create new serialization, input, export and privacy interactions. Keep those features in their separately scoped approved slices.

**Premise challenge:** prioritize qualification of the existing utility over any additional feature parity. This is the strongest risk-adjusted product strategy while native failures and physical checks remain, but it must not silently cancel the owner's broader approved feature work. The main session owns that priority decision.

Five years later, preserving explicit sanitized-export boundaries, small domain values, operation-local rendering geometry, regression evidence and truthful qualification labels should cost less than repeatedly reimplementing accepted paths or installing speculative caching abstractions. Future maintainers should rerun the behavior gate when changing these seams, not treat this dated source review as permanent certification.

## Verification commands for a future confirmed fix

No tests, builds, GUI actions or new reproductions ran in this advisory audit. The parent session supplied historical/current gate context: stable signed gate with 683 package tests and 617 translations; full native suite 45/47 in each language with the two excluded failures. Those are supplied evidence, not independently rerun results from this lane.

Only execute the following after a distinct confirmed finding and scoped fix exist. Read `AGENTS.md`, matching `BACKLOG.json`/acceptance cases and relevant Swift/Xcode skills first; use synthetic fixtures, preserve the dirty `docs/handoffs/` directory, inventory build artifacts and disk space before building, and run serially.

```sh
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer swift test --package-path Packages/RecortiaKit --filter PixelSamplerTests
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer swift test --package-path Packages/RecortiaKit --filter EditorPixelToolsTests
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer swift test --package-path Packages/RecortiaKit --filter EditorPaletteTests
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer swift test --package-path Packages/RecortiaKit --filter EditorCurvedArrowTests
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer scripts/check.sh
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer scripts/e2e.sh --lang all
```

Choose only the affected focused suites, add the specific behavioral regression and observe it fail before source changes, then make it pass and run the repository gates. Text/imaging/geometry/privacy edits additionally require their existing text, line/curve export and RED families plus exported pixel/metadata comparison. A passing unit suite cannot replace these. Native full-suite success requires every scenario PASS per language; preserve any original failure and activation-control skip. Physical VoiceOver/IME/TCC/Spaces/displays, minimum-macOS behavior, signing/notarization and release qualification remain distinct.

Because there is no new confirmed finding, there is no honest new red-test proposal in this disposition. Any future executor must first supply exact trigger, expected contract, current-source location and failing assertion; do not invent a test solely to justify a speculative change.

## Done and stop conditions

- [x] Fixed base/HEAD recorded and prior advice reconciled.
- [x] Current source/caller evidence inspected for each concrete disposition above.
- [x] Introduced versus pre-existing findings distinguished; zero confirmed residual plans.
- [x] No source edits, test/build/GUI execution, commits, pushes or private-data operations.
- [ ] Main session may link this disposition from its plan index; no implementation dependency is created.

Stop before any implementation based only on this document. A drifted HEAD or changed cited seam requires rereading the current code and prior corrections. A new permission, provider, persistence mechanism, architecture replacement, proprietary-parity claim or production/release action is outside this audit. Never reinterpret the two excluded native failures as host noise or fixed solely from a passing rerun.

Read-only audit commands included `git status --short`, `git rev-parse --short HEAD`, the fixed-base changed-file inventory and focused diffs, plus bounded `rg`, `cat`, `sed` and line-numbered source reads. The initial worktree contained only unrelated untracked `docs/handoffs/`; it was preserved. No task-owned processes or temporary build directories were created, so none require cleanup.

`codemap --importers ../../PROJETOS/recortia/plans/002-post-install-deep-review.md` exited 0 but reported the Markdown plan **not indexed**. This is not a confirmed zero-importers result. Codemap also declares partial Swift coverage that can miss extensions/protocol/generic references; inspected caller code, rather than this result, supplied the blast-radius assessment. `git diff --check` exited 0 for tracked changes; the new untracked plan requires its own whitespace check before handoff.
