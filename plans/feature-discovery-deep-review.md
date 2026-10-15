# Feature discovery: bounded deep advisory review

Planned at commit `53c4d81`, branch `feat/onboarding-feature-guide`, 2026-10-14.
The inspected working tree includes uncommitted onboarding changes and untracked specification
documents. This is a source-backed advisory audit, not a frozen-candidate acceptance result.

## Assumptions and scope

- The owner requested no interview. The native macOS screenshot product, macOS 15 minimum,
  active-Space policies, volatile documents, and ShareSnapshot export boundary remain binding.
- A request for all reference features does not resolve conflicts with the repository's explicit
  recording, archive, network-provider, automation, or credential boundaries. Those are visible
  blocked product decisions, not completed features.
- This review covers feature discovery, its Settings/capture callers, and missing local editing
  seams. It does not duplicate a full code-style/diff review. No source edits, builds, tests,
  private desktop reads, credential access, reference-app launch, or external writes occurred.
- Only this consolidated plan is produced; no plan index, extra ticket, agent, or temporary copy
  is created. The operator owns the implementation decision and the delivery workflow.

## What the review changed

1. Correct the tour's safety advice about automatic exports: later redaction cannot recall an
   earlier clipboard, file, or remote copy.
2. Split existing editor aspect constraints from missing capture freezing and object snapping.
3. Treat local parity as independent vertical slices, not a checklist that a seven-page tour
   can complete. Add an explicit status, entry point, test and limitation per capability.
4. Prefer bounded local improvements before the high-risk geometry, scroll, persistence and
   cloud expansions. Measure actual performance; resource presence is not algorithm evidence.

## Confirmed findings

| ID | Finding | Impact | Effort | Change risk | Confidence |
|---|---|---|---|---|---|
| FD-01 | Replace impossible automatic-export advice | A user may infer that masking after capture fixes the first exported copy | S | LOW; localized education only | HIGH |
| FD-02 | Split existing constraints from missing capture features | The inventory under-teaches existing behavior and can commission duplicate work | S | LOW; traceability correction | HIGH |
| FD-03 | Expand the reference inventory into atomic behaviors | Grouped families cannot establish every-feature parity or executable acceptance | M | LOW for inventory; feature implementation risks remain separate | HIGH for identified omissions, not exhaustive completeness |

### FD-01: Explain the first-export boundary accurately

Evidence:

- `RecortiaApp/Onboarding/OnboardingView.swift:217` says automatic exports occur before later
  editor changes, then advises the user to "redact first and export again".
- `RecortiaApp/App/AppModel.swift:253–283` opens the editor and starts automatic exports from
  the fresh capture; current-session checks cancel stale work but cannot recall a committed sink.
- `RecortiaApp/Settings/SettingsView.swift:164` already says these operations precede edits and
  cannot be taken back from other apps.
- `RecortiaApp/Settings/GitHubUploadSettings.swift:125,142` explicitly states pre-redaction
  timing and irreversible remote copies. `SPEC.md:132–140` limits the promise to new artifacts.

Fix sketch: Tell users to disable automatic copy/save/upload before capturing sensitive content.
State that later edits affect new exports and do not remove earlier copies. Repeat the
pre-redaction timing in the GitHub page instead of relying on the preceding page's wording.
Preserve opt-in defaults and the stronger Settings consent dialog.

Verification: inspect the EN and pt-BR rendered sharing page and the real Settings explanations
together. Run the existing onboarding and automatic-export scenarios; text-only checks are not
a substitute for human comprehension. No new automatic-export implementation is needed.

### FD-02: Do not classify existing editor constraints as missing

Evidence:

- `docs/specs/feature-discovery/reference-matrix.md:38` groups smart selection/snapping,
  frozen selection and aspect constraints under "No equivalent verified / not implemented".
- `Packages/RecortiaKit/Sources/Features/EditorModel+Gestures.swift:189–199` preserves layer
  and text aspect ratios and supports Shift-constrained resize.
- The same file at `213–233` constrains shapes and crop regions with Shift; `239–248` snaps
  Shift-created arrows to 45-degree increments.
- `Packages/RecortiaKit/Tests/FeaturesTests/EditorCompositionTests.swift:96–105` checks image
  layer aspect preservation during corner resize.

Fix sketch: Use separate rows for existing editor constraints, explicit crop ratio presets,
capture size/aspect locking, captured-background freezing, semantic selection, and object/edge
snapping. The current source proves the first row, not the others. Teach useful existing Shift
behavior without claiming equivalent reference-app capture selection.

Verification: `EditorCompositionTests` remains green; add gesture characterization tests only
where documenting a concrete behavior that the present tests do not assert. No capture refactor
is required to correct the inventory.

### FD-03: Atomic coverage is still missing

Evidence:

- `docs/specs/feature-discovery/implementation-plan.md:41–45` requires individually actionable
  missing-feature slices and explicitly forbids closing the broad request after writing tickets.
- The feature-discovery directory currently has only `01-first-run-tour.md` as a ticket.
- The official [CleanShot feature list](https://cleanshot.com/features) separately documents
  a line tool, text styles, saved colors, crop ratio/edge snapping and background Auto Balance.
  These behaviors are not individually accounted for in the present reference matrix.
- `Packages/RecortiaKit/Sources/Features/EditorTypes.swift:10–31` has no standalone line tool.
  `Domain/Annotation.swift:6–13` represents text and straight arrows, not a styled-line family.

Fix sketch: Add one row per observable behavior with source date, implementation symbol,
acceptance test, status and protected decision. Split "WebP/HEIC, multipage print", "Average/text
color, OKLCH, APCA" and "presets/image backgrounds"; their risks and done conditions differ.
Saved color and text-style availability still needs a focused source inventory before calling
them confirmed absent. A product page can prove a reference claim but not equivalent internals.

`SPEC.md:14` still describes Shottr 1.9.2 as current; the live official page and the new matrix
say 1.9.3. Keep the original research dated, or update the statement and provenance together.
Do not silently replace the original evidence scope with newly inferred binary behavior.

## Local feature direction: recommended execution order

These are grounded options, not defects in an approved v1 contract. Estimates include tests.
Use one coherent slice per commit/ticket. Land FD-01/02 and freeze the atomic inventory first.

### 1. Atomic, reusable presentation presets — M, LOW/MED risk

User value: apply consistent framing without repeating background/padding/corner/shadow edits.
Current seam: `Domain/Document.swift:159–187` stores a value `Presentation`;
`EditorModel+Composition.swift:222–247` exposes separate validated setters;
`EditorInspectorView.swift:651–716` exposes the same parameters. Existing composition tests at
`190–207` demonstrate four independent undo steps. A preset must be one atomic edit, not four
calls to those setters.

Chosen approach: first add native built-in presets and an atomic apply operation. Then, if the
same approved slice includes reuse across launches, persist only a bounded name plus the
parameter value in Settings. Do not persist screenshots, document geometry, background image
paths, or source assets. The strongest rejected alternative is snapshotting documents as
presets: that expands persistence and exposes content without helping parameter reuse.

Blast radius: `Domain/Document.swift`, `Features/EditorModel+Composition.swift`,
`RecortiaApp/Editor/EditorInspectorView.swift`, `RecortiaApp/Resources/Editor.xcstrings`,
`FeaturesTests/EditorCompositionTests.swift`, `ImagingTests/RenderCompositionTests.swift`,
`RecortiaApp/E2E/Scenarios+Editor.swift`; SettingsStore and its tests only for metadata reuse.
Verify the actual String Catalog path before editing; do not create a parallel catalog.

Tests first: apply changes every parameter in one undo step; Undo/Redo exactly restores values;
invalid/non-finite values leave the document unchanged; stale preview/drag is invalidated;
masked-source output remains independent of secret pixels after every preset. Persistent
metadata, if selected, needs bounded names/counts, malformed-load rejection, and no asset/path
serialization. Compare the actual exported raster and preview, including crop and scale.

### 2. Bounded sRGB area and text-color sampling — M, MED risk

User value: inspect representative colors without fragile one-pixel aiming.
[Shottr's public tips](https://shottr.cc/) document area-average and nearby dark-pixel selection.
Current seam: `Imaging/PixelSampler.swift:9–27` samples one pixel; each call allocates a 1×1
raster. `EditorModel+PixelTools.swift:43–55` gates sampling on the current sanitized base;
`EditorPixelToolsTests.swift:123–139` proves stale redaction state is refused.

Chosen approach: render one bounded selected tile and compute its result off MainActor. Define
the average mathematically before coding: linear-light sRGB average of visible pixels with
alpha weighting, then encode sRGB; fully transparent input yields no visible-color result.
Label the operation accordingly. Text color is a separate explicitly named heuristic with a
bounded neighborhood; do not claim font-color detection. Preserve single-pixel HEX/RGB behavior.
Reject an implementation that loops over `PixelSampler.color` for every pixel: repeated context
allocation turns an adjacent feature into an avoidable performance problem.

Blast radius: `Imaging/PixelSampler.swift`, `Features/EditorModel+PixelTools.swift`,
`Features/EditorTypes.swift`, `RecortiaApp/Editor/EditorInspectorView.swift`, editor localization,
`ImagingTests/PixelSamplerTests.swift`, `FeaturesTests/EditorPixelToolsTests.swift`, synthetic
fixture helpers, and the existing `pixel-tools` E2E scenario. No ImageStore raw read or new sink.

Tests first: known linear-light and encoded-sRGB charts distinguish the chosen definition;
transparent pixels cannot influence RGB; bounds at every canvas edge; empty/non-finite/oversized
selection fails explicitly; zoom and imported point-scale independence; work cannot finish into
another revision/privacy epoch; both differing-secret fixtures produce the same masked result;
Copy invokes only the explicit text sink. Record bounded memory and cancellation behavior.
OKLCH and contrast standards are separate later slices, not incidental numeric additions.

### 3. Curved/styled arrows through the shared renderer — L, MED/HIGH risk

User value: direct attention around content without drawing a separate freehand path.
The references document multiple arrow styles and bends. Recortia's `Annotation.Kind.arrow`
currently contains only start/end (`Domain/Annotation.swift:8`). Its bounds, translation, resize,
hit testing and export are tied to that shape; `AnnotationRenderer.swift:105–125` draws a fixed
straight shaft and filled head. `SPEC.md:128` explicitly allows basic arrows before curved ones.

Chosen approach: add one control point and explicit arrow style to a typed domain geometry,
retain straight arrows as the zero-curvature case, and derive the arrowhead from the terminal
tangent. Use the exact same geometry for preview, bounds, handles, hit testing and export.
Reject an editor-only decorative curve: it would disagree with sanitized output.

Blast radius: `Domain/Annotation.swift`, `Features/EditorTypes.swift`, `Features/EditorGeometry.swift`,
`Features/EditorModel+Gestures.swift`, `Features/EditorCanvasRenderer.swift`,
`Imaging/AnnotationRenderer.swift`, editor inspector/canvas/string helpers, and corresponding
domain, renderer, replay, redaction and synthetic `annotations` tests. Inventory every exhaustive
arrow switch before committing to this slice; rotation/callout APIs stay untouched.

Tests first: terminal tangents and head bounds for zero-length/short/high-curvature paths;
non-finite geometry refusal; exact translation and resize of the control point; handles/hit
testing at multiple zooms; one gesture per undo; keyboard control while text/IME owns focus;
deterministic raster output; secure masks cover intersecting vector/text pixels in PNG/JPEG,
clipboard and drag exports. Do not use aesthetic snapshots as the only geometry oracle.

## Higher-blast-radius work: design before implementation

- Rotate/flip: `LayerPlacement.rotation` already exists and source-to-document mapping composes
  it (`Domain/Document.swift:64–108`), but there is no complete user-command contract. Pick
  selected-layer rotation versus whole-document rotation before coding. Flip is not represented
  by uniform positive scale. Test source-bound masks, repeated asset references, document-space
  vector masks, source crops, callout source/destination rectangles, canvas fit, ruler point
  eligibility and undo together. Never fake a flip by negating scale without those invariants.
- Horizontal scroll: capture target binding, overlap matching, calibration, memory limits and
  partial-result UI require an axis-aware contract and a synthetic corpus. Transposing two
  images alone does not prove focus/cancellation/limit safety for a live session.
- Capture freezing or quick-action overlay: changing when pixels are acquired or when an
  editor becomes visible must preserve CAP-01/02, `editor-presentation`, Space policy and the
  original consent identity. It is not a window-style-only feature.
- WebP/HEIC and print: verify actual platform encode/decode support first. Add codec-specific
  bounded/malformed-input and metadata/alpha-redaction controls. Print only a ShareSnapshot;
  never pass Document/ImageAsset directly to a print subsystem.
- Image backgrounds: every new raster reference must enter import admission, source masking
  and release accounting. Parameter presets do not establish that boundary.

## Protected or unknown boundaries

Recording/audio/camera/keystroke visualization, always-on capture, automatic local history,
proprietary cloud collaboration, telemetry, S3 credentials/providers and FR-16 integrations
remain outside the present safety design. Persistent editable projects would retain original
assets and undo history, directly changing the privacy promise. Always-on-top/click-through
pins conflict with ADR-007's switchable ordinary-window decision and need a recovery design.
Do not mark any of these PASS, silently reinterpret them, or add placeholders that appear done.

Reference asset counts and bundled tools can establish presence only. They do not disclose
matching heuristics, caching, frame pacing, security or memory quality. Proprietary optimization
parity remains unknown. Cosmetic blur/pixelation must not inherit another product's marketing
security label; Recortia's source-pixel replacement contract stays authoritative.

## Performance: evidence before optimization

`BACKLOG.json:18` records editor and first-open Settings missing the 50 ms PERF-02 regression
budget, with FP-028 deferred by the owner. This is an observed existing limitation, not a new
profiling result. Before changing view construction, freeze Debug/Release, cold/warm endpoints,
hardware and sample counts. Compare `window-latency` before/after and keep all original failures.
Use allocation/CPU traces to choose a bottleneck; do not infer wins from function complexity.

Investigate one parameter edit/preset producing multiple render tasks, or expensive per-pixel
sampling, only with an observable workload. No such runtime defect was measured in this audit.
Do not add global caches, pre-warm hidden windows at launch, or retain full-resolution document
copies solely to chase a number without idle-memory and lifecycle evidence.

## Exact verification gates for executors

All commands below are repository-defined entry points and were inspected, not run here. Use
stable Xcode and synthetic sinks. Serial execution avoids competing builds on the low-free-space
host. Each new behavior test must fail before its implementation and then pass afterward.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/RecortiaKit --filter OnboardingModelTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/RecortiaKit --filter EditorCompositionTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/RecortiaKit --filter RenderCompositionTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/RecortiaKit --filter PixelSamplerTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/RecortiaKit --filter EditorPixelToolsTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/RecortiaKit --filter AnnotationRendererTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/RecortiaKit --filter EditorReplayTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/check.sh --unsigned
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/e2e.sh --lang all --only onboarding,automatic-export,annotations,redaction,pixel-tools,composition
```

Expected result: exit 0 for affected tests and the gate; every named E2E scenario reports PASS
in EN and pt-BR. Extend existing scenarios through real commands/controls, not offscreen-only
model state. Then run the full bilingual E2E gate. Geometry/imaging changes require the RED
family and actual exported pixel/metadata comparisons. Synthetic accessibility labels do not
qualify physical VoiceOver/IME, TCC, display/Space behavior, stable-host performance or signing.

Before implementation, compare cited excerpts with the current tree and `git diff --stat`
because this plan was written amid uncommitted work. Read AGENTS.md, SPEC.md, the selected
BACKLOG task and matching acceptance cases. If the required change adds a new permission,
external provider, screenshot persistence, unsafe export representation, or overlapping writer,
stop that slice and report the exact boundary; continue independent approved work.

## Strongest alternate strategy and five-year check

The strongest alternative challenges feature-count parity: finish discovery and qualify the
existing capture/redaction/Space behavior plus measured latency before adding more tools.
It has the best risk-adjusted path to a trustworthy screenshot utility, but does not satisfy a
literal request for all safe reference features. Record that tradeoff; do not quietly narrow the
owner's request. A phased implementation of atomic safe slices is the chosen execution shape.

Five years later, explicit coordinates, bounded allocations, editable values, native controls,
one export renderer and truthful consent remain cheaper to maintain than mimicking reference
interfaces or reverse-engineering unpublished optimizations. Keep capability evidence next to
each acceptance test, and keep every blocked reference item visible.

## Audit execution evidence and limits

- Read current feature-discovery docs, root instructions/spec/plan/acceptance sections, relevant
  onboarding/AppModel/Settings paths, annotation/render/pixel/composition/gesture seams and tests.
- Read the official [Shottr page](https://shottr.cc/) and
  [CleanShot feature list](https://cleanshot.com/features) on 2026-10-14. No reference app ran.
- `git status --short`, `git branch --show-current`, `git rev-parse --short HEAD`: current branch
  and dirty-state evidence are stated at the top. No reset, stash, commit or source write occurred.
- `cccc --version`: 1.8.0. Focused `cccc --no-cache --min 0` over the three Features files
  `EditorModel+PixelTools.swift`, `EditorModel+Composition.swift`, `EditorModel+Gestures.swift`
  exited 0; expected/analyzed files 3/3, 101 functions including closures, parse errors 0.
  No `cccc.toml` was found in the repository or inspected parent directories. No thresholds
  were introduced. Cognitive maximum 43 locates review work; it proves no runtime defect.
- `codemap --importers ../../PROJETOS/recortia/plans/feature-discovery-deep-review.md`
  exited 0 but reported the Markdown plan as not indexed. This is not zero-importer evidence;
  its Swift map also declares partial extension/protocol/generic resolution. Blast radii above
  come from inspected source and must be reconciled again by each executor.
- Tests/builds, native UI, benchmarks, independent release acceptance, signing/notarization,
  full dependency/security audit, every repository package and all reference settings were not
  audited or executed. No competitor-parity, full-scope completion, or production-ready claim
  follows from this plan. No task-owned temporary files or processes require cleanup.
