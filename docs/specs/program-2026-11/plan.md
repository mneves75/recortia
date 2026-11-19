# Recortia program 2026-11 — macOS 26 refresh, full review, every reference gap, auto-redaction

Status: approved by the owner on 2026-11-19. T0 in progress (FP-047).

## Context

Owner request 2026-11-19: improve UI/UX and visuals (the 0.14 redesign fell short); read the whole
project and fix what is broken, inconsistent, inefficient or no longer needed (certain items fixed,
the rest listed); fewer, deeper modules with smaller interfaces, one admission check per input,
one-off logic inline; bring the source to 2026 practice with the Xcode-beta/Swift skills; reverse
engineer the installed reference app with REA and implement every capability Recortia lacks; add
an optional "redact e-mails and phone numbers on capture" setting modelled on Fosco
(github.com/gabrielbuzziv/fosco, MIT). New branch and worktree; this session plans, advises and
reviews; executors build from written specs.

**Owner decisions taken 2026-11-19 (in this session's question dialog):**
1. Scope: class A **and every class-B item** ("implement everything"). Class C stays excluded by
   AGENTS.md's non-negotiable boundaries (recording, audio, camera, keystrokes, cloud accounts,
   history archive, telemetry).
2. **Deployment floor raised to macOS 26** (was 15.0, decided for 0.14 on 2026-11-10).
3. Design seat stays **Opus 5.5** (this session) with the Fable 5.2 advisor reviewing.
4. **Full REA analysis** of the reference app (licence read first; see T0.2).

Real users exist (no "no real users" declaration in AGENTS.md): sealed preference blobs stay
decodable (`Bool?` pattern), public behaviour changes are recorded in CHANGELOG/README, and the
macOS 15 drop is announced.

## Red team

### Played back
1. Fable orchestrator, new branch/worktree; this seat plans, advises, reviews; Opus 5.5 medium,
   Codex and Pi build from specs; the hardest parts may stay here.
2. Improve UI/UX, visuals and design.
3. Read everything; fix certain defects, inconsistencies, inefficiencies, dead code; list the rest.
4. Review toward fewer, deeper modules, smaller interfaces, check once at entry, inline one-offs.
5. Modernise to 2026 practice with the Xcode-beta/Swift skills.
6. REA the reference app; implement every capability Recortia lacks.
7. Optional auto-redaction of e-mails and phones on capture.

### Facts that bend it
- This session is Opus 5.5 (routing rule 2026-11-11), not Fable; you chose to keep it so. The
  design loop below (screenshots judged by eye, Fable advisor review, your yes/no on before/after)
  is what changes the outcome, not the seat.
- Most analysis exists, 8–9 days old: `docs/specs/code-review-2026-11/findings.md`,
  `docs/specs/enhancement-plan-2026-11/plan.md` (class A/B/C), `feature-discovery/reference-matrix.md`.
- The reference app's Settings labels (read from its compiled storyboards, no code decompiled) add
  small items only: Retina→1× downscale, automatic PNG/JPEG, window-capture background colour and
  shadow trim, default and wheel zoom, OCR line-break handling and primary language, hide the
  menu-bar icon.
- AGENTS.md forbids naming competing products in code, docs and commits: the reference app is never named in
  the repository.
- Fosco is one day old (4 commits, 0 stars); its detector uses `try!`, its clipboard guard polls
  the pasteboard — both forbidden here. Port the patterns and tiling only (MIT, credited, pinned).
- SPEC:405 allows sensitive-data *suggestions* only; automatic masks need a written FR-06/§13 amendment.
- Native E2E (the only visual proof) needs an idle, unlocked console; you were active 18 s before
  I checked, so foreground results now would be void.
- Owner rule: architecture/simplification requests get Gemini's plan via `agy` first.
- Security waivers SEC-11/17/18 expire **2026-11-25**; no release from this program before they are
  resolved or re-waived.

### Six months on it failed — three likeliest reasons
**1. Optimism: one branch carried everything.** Trigger: >3k changed lines before the first
merge, or scenarios failing for reasons unrelated to the slice. Cost: weeks stranded, or a merge
that regresses ShareSnapshot/privacy-epoch/Space invariants built over 14 releases. Experiment:
time one S slice (A-1 window titles) through the full loop — failing test, fix, gate, bilingual
E2E, cross-model review. **Answer built in:** ship as trains T1–T6, each a PR merged before the next
branches.

**2. Unchecked assumption: the UI failed because of the executor.** 0.14 was specified as
"structure, not styling", system controls only, verified by geometry/contrast checks; nobody judged
screenshots by eye. Trigger: you see the first refreshed surface and say "still not good". Cost: a
second redesign thrown away. Experiment: today's screenshot set of every surface, a ranked critique,
a throwaway spike of the editor on macOS 26 containers, before/after in front of you. The spike
must also prove all toolbar items stay visible at 980 pt and the remembered content size holds.

**3. Failure case not considered: auto-redaction leaks.** Automatic copy/save/upload is frozen
synchronously at capture completion; recognition takes 0.3–1.5 s. Detect after the freeze and masks
miss the clipboard/upload; wait before it and a Settings change joins the batch (the R-3/SR-1 defect
fixed in 0.14). OCR misses small/1× text that people stop checking. Experiment: recall/latency spike
on synthetic fixtures + a failing test that auto-copy with the setting on publishes masked bytes.

**Simpler route:** decisions answered (done above), then trains. **Verdict: run the three experiments
first (T0), then ship in trains.** "Everything in one branch" is torn down; nothing else is.

## Findings to act on

### Certain fixes (T1, each with a failing-first test where behaviour changes)
- **Hosted CI is red on `main` since 2026-11-11** (run on `b2726b4`): `doctor: Xcode 27.0 (27A266a;
  /Applications/Xcode_27.app) != stable baseline 27.2 (27B52)`. The workflow comment still says
  27.0 is the baseline (`.github/workflows/ci.yml:18-22`). Fix first in T1: list the runner's
  `/Applications/Xcode*` and OS version in a CI step, select 27.2 via `DEVELOPER_DIR`, and confirm
  the runner OS is ≥ 26 before the floor rises.

Architecture audit 2026-11-19 (paths under `Packages/RecortiaKit/Sources/` unless `RecortiaApp/`):
- Dead code: `ImportCoordinator.clearFailure()` (`Features/ImportCoordinator.swift:72`),
  `EditorModel.setRuler(from:to:)` (`Features/EditorModel+PixelTools.swift:26`),
  `EditorTool.isSecureRedaction` (`EditorTypes.swift:65`), `EditorWindowManager.openDocumentIDs`
  (`RecortiaApp/Editor/EditorWindowManager.swift:57`), `Preferences.launchAtLogin`
  (`Domain/Policies.swift:203`; `LoginItem` is the truth; old blobs still decode). Keep
  `updateChecksEnabled` for B-5.
- Test-only members and their tests: `Document.isPartialScrollCapture`, `Document.maskedRegions`,
  `Annotation.outsetBounds`, `DocumentSession.redoLabel`, `EditorTool.createsObject`,
  `EditorMeasurement.distancePoints`, `ShortcutStatusModel.hasFailed`; 3 stale keys in
  `RecortiaApp/Resources/Localizable.xcstrings`.
- Composition root: move `AppServices.live()` and `LiveStitcher` from
  `RecortiaApp/App/LiveRecognition.swift:43,78` to `AppServices.swift`; drop the stale comment
  (`AppServices.swift:4-6`); make `AppModel.init(services:)` non-optional (previews get a preview
  `AppServices`), deleting 21 `features?` sites in `AppModel` and 5 in `SettingsWindowController`.
- One export-failure mapping in `UserMessage` (today `EditorStrings.swift:253-270` and
  `MessagePresenter.swift:145-167` word it differently); inline the one-caller forwarders
  `EditorStrings.importMessage`/`automaticExportFailure` and
  `SettingsStore.chooseAutomaticSaveFolder`.
- Duplicate kind mapping in `Features/EditorModel.swift:334-338` vs `:374,388`.
- GitHub token shape validated three times (`GitHubUploadSettings.swift:50`,
  `MacPlatform/GitHubTokenStore.swift:45`, `GitHubUploader.swift:82-85`): one admission point in
  `GitHubTokenStore`. Credential path → security review.
- One ordinary-window presentation function in `AppPresence` replacing four hand-sequenced copies
  with three orderings (Settings, onboarding — which calls `windowWillAppear` twice — editor, scroll
  review). Window-presence/Space area: rerun `window-presence`, `space-policy`, the space probe's
  `dynamic` mode and the installed-app fullscreen check.
- UI: blue-to-purple default background gradient (`RecortiaApp/Editor/EditorInspectorView.swift:1057-1060`)
  → neutral default; toolbar `Spacer` hack (`EditorRootView.swift:129`) → `ToolbarSpacer` (macOS 26).

### For you to review (listed in `docs/specs/program-2026-11/review-list.md`, not changed)
Measure-first performance: canvas redraws everything on any observed change and fills the
checkerboard per 8-pt tile (`EditorCanvasView.swift:112-125,197,262-280`); OCR/QR re-render the base
(`EditorModel+Recognition.swift:25,108`); each automatic step renders separately
(`ExportCoordinator.swift:184`); bookmark resolution on the main actor three times per batch
(`:337-390`). Shape: two recognition protocols over one adapter; `GitHubDestination.isValid` at five
sites vs a failable init and Codable decode; delay clamp twice (public entry); 47 per-method
`isFinite` guards in `EditorModel*` vs one typed admission; two export-format enums (blob schema);
the production test counter `listItemGeometryResolutions`; E2E (9.8k lines) larger than the app
(8.4k). 2026 hardening: Enhanced Security (the macOS 26 floor removes one of its three blockers,
`docs/specs/release-review-0.12.5/xcode-security-settings.md`), Swift 6.2 `Span` and strict memory
safety for the 15 unsafe-pointer sites (`MacPlatform/FileSink.swift`, `Imaging/RenderRaster.swift`, …).
Plus whatever T0.3/T0.4 add.

### UI audit (code-level; screenshots in T0.1 confirm or overturn)
Editor panes are an `HStack` with `Divider`s and fixed 220/290 pt (`EditorRootView.swift:26-36`),
not `NavigationSplitView` + `.inspector`; Delete/Arrange in three places, Crop in two; ~30 controls
for one selected boxed text; helper text in three styles, Privacy Settings is eight paragraphs, a
permanent instruction label on the region overlay, an onboarding tagline; corner radii 3/4/6/8,
three warning backgrounds, two selection idioms, paddings 8/10/12/16; no materials on HUD, choosers,
drag chip, pins; custom tiles where a segmented `Picker` or `.badge()` fits; modal informational
alerts beside inline notices; status bar clips two-line notices; canvas has keyboard control but no
focus ring; accessibility display-option changes not observed; reduce motion handled in two places.
Base is sound: text styles throughout, no hard-coded chrome colours.

**Direction (macOS 26 floor):** standard containers in their Liquid Glass form —
`NavigationSplitView` sidebar, `.inspector`, the bridged toolbar grouped with `ToolbarSpacer`,
`NSGlassEffectView`/`.glassEffect` on floating panels (HUD, choosers, pins, drag chip), glass
buttons only for floating actions; one token set (one radius per element class, one spacing scale,
one notice style); one place per command (toolbar or inspector, context menu mirrors); no helper
text or taglines; editor-scoped messages as sheets, app-level as alerts; canvas focus ring;
observe display options; reduce motion everywhere. Region overlay stays two-tone and identical in
both appearances (AGENTS.md). Use the `swiftui-liquid-glass`, `swiftui-whats-new-27`,
`swiftui-ui-patterns`, `swiftui-performance-audit` and `mac-design` skills. Risk to prove in the spike: glass translucency vs `ChromeAppearance` dark thresholds
(median ≤ 0.10, ≤ 3 % near-white); never weaken that judge without a written reason and review.

### Auto-redaction on capture (main session keeps the ordering and fail-closed parts)
- **Spec first:** owner-requested amendment to FR-06 and SPEC §13: opt-in automatic secure masks from
  deterministic on-device recognition and fixed patterns (no AI), described as a review aid that
  cannot find every address or number. Credit "Fosco by Gabriel Buzzi (MIT)" in third-party notices
  and the ported file headers, pinned to the commit used.
- **Where:** `Features/CaptureCoordinator.swift:276-324` `run`, after `assets.registerCapture` (:303)
  and before `DocumentSession(document:)` (:319) / `onCaptured` (:323); state stays `.capturing`, so
  a repeat is ignored and cancel works. Skipped for `CapturePurpose.recognizeText`.
- **Freeze does not move:** when `capture.capture` returns, the coordinator synchronously reads the
  auto-redact preference and freezes the export plan through one injected main-actor closure, carries
  both to `onCaptured`; `AppModel.runAutomaticExports` (`AppModel.swift:316-335`) uses the carried
  plan instead of calling `automaticExportPlan()` itself.
- **Detection:** one Imaging file (`SensitiveText.swift`) with the tiled sweep (Fosco's 4-MP tile
  layout) calling the existing `Imaging/TextRecognizer.swift` per tile, sub-range boxes from
  `RecognizedText.boundingBox(for:)`, matches outset to whole pixels, appended as
  `SecureMask(outputRect:sourceRegions:fill:)` to the initial `Document` (editor opens clean; masks
  are ordinary, deletable). Capture Text and editor OCR keep their single pass unless the spike shows
  byte-identical text with tiling. Patterns validated once, no `try!`. A-6 (click a text line to
  redact) later reuses the same sweep.
- **Fail closed:** error, cancel or deadline → capture opens unredacted with a notice; that capture's
  automatic batch is skipped through the existing failure-message path. Found nothing → normal.
- **Visible wait:** spike p95 ≤ ~0.5 s → keep this design, menu-bar icon shows progress; above →
  build the alternative (open the editor at once, lock its exports and the batch until masks land as
  one undo step).
- **Setting:** `Preferences.autoRedactsSensitiveTextChoice: Bool?` + computed accessor (the
  `keepsRunningInMenuBarChoice` pattern, `Domain/Policies.swift:216-227`), Settings › Privacy ›
  Redaction (`RecortiaApp/Settings/SettingsView.swift:275-305` gains a `settings` parameter; callers
  `SettingsWindowController.swift:70`, `E2E/Scenarios+Shell.swift:474`); reword the Export footer
  (`SettingsView.swift:203-205`); pt-BR strings. SPEC's 300 ms capture-to-editor p95 gains a stated
  exception for this opt-in path with the measured number.
- **Scope:** region/window/display/repeat captures. Scrolling, import, paste and the B-1 thumbnail
  show the same redacted document where they reach it; adding detection to scroll/import is T2.
- **Proof:** RED family with planted controls (8–24 pt, 1×/2×, light/dark, EN/PT-BR addresses and
  numbers fully covered in copy, save, drag and pin bytes); failing-first: auto-copy publishes masked
  bytes; turning save/upload on or changing the folder during detection does not join the batch;
  fail-closed on error/cancel/timeout; cancel, replacement and failure during detection release the
  `ImageStore` asset (a new cancel point with raw pixels already admitted); legacy-blob decode;
  bilingual `auto-redaction` E2E. Hosted CI has no Vision (`RECORTIA_VISION_UNAVAILABLE`), so the
  freeze, fail-closed, release and masked-bytes guards run on a fake recognizer; only the recall
  benchmark needs real OCR (local gate).

## Execution

Worktree `../recortia-worktrees/refresh-2026-11` on branch `feat/refresh-2026-11` from `main`
(`b2726b4`); parallel executors get their own worktrees under `../recortia-worktrees/<slice>` on
branches off the train branch, removed after their merge (`git worktree remove`, `git branch -d`).
E2E from any worktree takes the **main checkout's** lock (`.scratch/e2e.lock` of the primary checkout),
redirects output to a file, and runs only when the console is unlocked and idle ≥ 5 min (a Monitor
waits for it); void runs are never acted on. The program plan and tasks are checked in
(`docs/specs/program-2026-11/plan.md`, BACKLOG FP-047…) so work survives context loss; a progress
dashboard via `dashboard-builder`. Commit and push the working branch after each verified unit;
PRs per train; merging and releasing are yours. If a train's PR is still unmerged, the next train
branches from it (stacked) and, after your squash merge, merges `main` in — never a rebase or
force-push.

SDK check 2026-11-19 (MacOSX27.2.sdk): `NSGlassEffectView`, SwiftUI `ToolbarSpacer`,
PackageDescription `.v26` and Vision `RecognizeDocumentsRequest` exist; whether Vision reports
e-mail/phone data is still to verify. The Xcode-beta MCP is not connected in this session (no
tools listed); the Swift/SwiftUI skills stand in.

**Routing:** this seat — specs, ADRs, the design critique and direction, the auto-redaction freeze
and fail-closed code, acceptance, reading every diff and screenshot. Opus 5.5 medium
`frontend-engineer` — UI slices. Codex GPT-6.2 Sol medium (`codex-auto exec`; your idle quota) —
bounded feature slices and certain fixes. Pi (`opencode-go/deepseek-v4.1-flash`) — mechanical
test-first tickets (dead-code removals). Reviews cross models: Sol high reviews Opus builds, Opus
`reviewer` reviews Sol/Pi builds; risky slices (auto-redaction, token path, URL scheme/App Intents,
project files, S3, updater, share extension) also get `mneves-security` and an adversarial
fresh-context review. Gemini (`agy`, plan mode) gives the architecture second opinion. Briefs:
Goal / Where / Facts / Constraints / Done when, no advisor calls, bounded reads.

### T0 — evidence and experiments (no product code)
0.0 Record the 2026-11-19 decisions where executors read them before any dispatch: AGENTS.md
    (authority paragraph: class B approved, FR-16 and further providers approved for design; floor
    macOS 26; the "no API newer than macOS 15, no `#available`" rule replaced), SPEC §2/§3/§13,
    BACKLOG FP-047… and `docs/specs/program-2026-11/plan.md`.
0.1 Baseline in the worktree: `./init.sh check --unsigned`; bilingual `./init.sh e2e --lang all`
    when idle → the screenshot set of every surface, light/dark, EN/PT-BR.
0.2 REA: read the reference app's licence terms first; if they forbid decompilation, run only the
    static pass (UI strings, settings keys, symbol names, resources) and ask before decompiling.
    Output stays in the session scratchpad; the main session folds unnamed capability descriptions
    into `reference-matrix.md` and classifies them A/B/C. Nothing copied. The "nothing was
    disassembled or string-dumped" boundary text in `reference-matrix.md` and the enhancement plan
    is rewritten to say what was done.
0.3 Architecture second opinion: `agy` plan mode on the audit's structure list; put both side by
    side, note which deletes more code, then fix the T1 list.
0.4 Defect review of the whole project (the 2026-11-10 review covered 16 files and skipped the
    inspector): Codex Sol high, read-only, one pass per module (Domain, Imaging, MacPlatform,
    Features, RecortiaApp non-E2E, E2E harness) plus `scripts/`, CI and `project.yml`, `path:line`
    per finding; the main session verifies each before it enters a list.
0.4b Modernisation audit with `write-swift`, `swift-concurrency`, `swiftui-pro`,
    `swiftui-whats-new-27`, `app-intents-whats-new-27`, `swiftui-liquid-glass`,
    `audit-xcode-security-settings`: what the macOS 26 floor and Swift 6.4 let us delete or replace
    (availability-era workarounds, `Span` for unsafe pointers, App Intents patterns). Output feeds
    the certain-fix and review lists.
0.5 Experiments: (1) A-1 window titles through the full loop, timed; (2) editor spike on macOS 26
    containers + glass — prove 980 pt toolbar visibility, remembered content size, `ChromeAppearance`
    dark thresholds — and publish before/after as a private artifact; (3) auto-redaction spike:
    recall and p95 of the Fosco-pattern port vs `NSDataDetector` vs any Vision 26 detected-data API
    (verify in the SDK swiftinterface), on RecortiaFixtures images.
**Planned stops:** (a) your yes/no on the before/after screenshots and the spike numbers, at the
end of T0; (b) your sign-off on each ADR or threat model before its train builds on it: B-1
thumbnail (T2), B-7 Accessibility snapping and B-3 pins (T3), B-2 automation (T5), B-8 project
files and the S3 threat model (T6, SPEC §13 requires a separately approved one). Everything else
proceeds without asking.

### T1 → 0.15 "macOS 26 foundation"
ADR-008 macOS 26 floor (`project.yml` `MACOSX_DEPLOYMENT_TARGET`, `Package.swift` `.macOS(.v26)`,
AGENTS.md/CLAUDE.md "no API newer than macOS 15, no `#available`" rule replaced, SPEC §2, README);
certain fixes above; auto-redaction; editor refresh per the approved direction; token set; A-1, A-2
(Open With / document types), A-9 filename templates, A-12 optional capture sound, A-13 step 1
(latency signposts).

### T2 → 0.16 "surfaces and flow"
Refresh Settings (seven tabs, Privacy cut to essentials), onboarding, HUDs, choosers, pins, drag
chip, alerts; A-3 menu-bar commands; A-13 step 2 (pre-built windows, measured); the small REA items
(1× downscale, auto PNG/JPEG, window background/shadow trim, default and wheel zoom, OCR line
breaks/primary language, hide menu-bar icon); **B-1 quick-action thumbnail** (ADR: discard on
dismiss, default keeps opening the editor, automatic exports run before it shows); auto-redaction
for scroll/import.

### T3 → 0.17 "precise capture"
A-4 nudge/aspect/edge snapping; A-5 frozen frame + magnifier (after A-13 numbers); **B-7**
element snapping (ADR: new Accessibility use); **B-3** per-pin "Keep on top" + click-through with a
menu command that unlocks every pin (ADR-007 amendment).

### T4 → 0.18 "redact and present"
A-6 text-line redaction (reuses the sweep), A-7 colour formats + WCAG contrast, A-8 framing presets
and balance, A-10 duplicate/crop presets/rotate/flip (masks move with layers), A-11 arrowheads and
smoothing.

### T5 → 0.19 "integrations"
**B-2** App Intents (Capture Region/Window/Text, Open, Pin) then URL scheme, under "no silent
capture or export" (FR-16 design + ADR); **B-4** share extension; **B-6** restore last closed
(memory only, one slot, cleared on quit and timeout); **B-10** local diagnostics file (opt-in,
network-free, proven).

### T6 → 0.20 "files, formats, providers, updates"
**B-8** project files + Quick Look (threat-model ADR: source pixels under masks); **B-9** HEIC,
horizontal scrolling capture, printing, S3 provider (threat model per SPEC §13, synthetic endpoints
only, no real credentials); **B-5** Sparkle updater per `docs/specs/signed-updater/` — the EdDSA
key custody step is yours.

## Verification (every slice)
Failing test first, then `swift test --package-path Packages/RecortiaKit --filter <Suite>`;
`./init.sh check --unsigned` (format lint, project freshness after `xcodegen generate`, all tests,
Debug build, pt-BR coverage, E2E target build); bilingual `./init.sh e2e --lang all` for each touched
flow with screenshots judged by eye in light and dark; bad input tried (blank, wrong format, very
long, malformed images); RED family for anything touching masks, geometry, export or clipboard;
window/Space/activation changes rerun the space probe (the installed-app fullscreen check is
listed under Owner-only); `reviewer` agent before reporting each train done; each
train's report uses AGENTS.md's implementation-report block and lists every flow pass/fail.

## Owner-only
Merges and releases (security gate on the exact commit; waivers expire 2026-11-25); TCC grants and
live-capture QA on a test desktop; physical Space/display qualification; the installed-app
fullscreen check (it replaces your 0.14.0 in /Applications and needs the "Recortia Developer ID"
profile, so only with your OK at the time, keeping the previous bundle); idle-Mac windows for
native E2E; updater key custody; Homebrew cask minimum-OS bump. macOS 26.x itself is untested on this
Mac (27.3).
