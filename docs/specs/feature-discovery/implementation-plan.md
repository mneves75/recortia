# Implementation and acceptance plan

## What the review must challenge

### What the adversarial advisor changed

The advisor rejected any full-parity completion claim: seven feature families are not every
competitor capability, and writing tickets is not implementing them. The reference matrix must
track each gap and its real status. Replay now has explicit close/reopen/single-window behavior;
E2E must enter through the actual app command/controller and observe side-effect counters.
Installation and beta-tag evidence remain separate from notarization, public distribution and
physical qualification. This is a phased implementation with unresolved protected decisions,
never a claim that the entire broad request has already been fulfilled.

The weakest assumptions are that a feature list teaches actual use, that a tour can be replayed
without altering first-run/login semantics, and that competitor feature parity implies equivalent
security or performance. Review each explicitly before implementation and delivery.

## Alternatives and five-year decision

1. Retain two pages and link to a manual: smallest change, but fails in-app feature discovery.
2. Long mandatory tutorial with demos/permissions: richer teaching, but delays first value and
   risks stale fixtures, permission fatigue and maintenance cost.
3. Short skippable tour plus replay and truthful feature inventory: chosen. Native controls and
   the existing state machine survive SDK evolution; no tutorial-specific rendering engine.

Five years later, consent, predictable window behavior and honest qualification evidence matter
more than visual trends or copied feature counts. Keep metadata about capabilities adjacent to
the workflow, use no new dependency, and measure rather than promise competitor timings.

## Sequence / vertical slices

Continuation status: area sampling, straight lines and explicit saved colors have source and
regression evidence. Saved-color native controls now pass both languages after the synthetic
runner's self-scoped public AX query initializes lazy SwiftUI nodes and the offscreen editor
is ordered for interaction. Do not substitute offscreen cache rendering for real native actions.
Next gates are the corrected full E2E suite, independent native acceptance and exact-head CI;
then choose the next safe matrix gap (text style presets) before any release action. Curved
arrows and horizontal scrolling need separate geometry/matching regression slices. Recording,
audio/history/cloud and unknown proprietary internals remain protected or unverifiable.

1. Inventory: actual repo/toolchain/build-artifact state and installed reference versions;
   public docs, implementation evidence, reference gaps and protected boundaries.
2. ONB-01 / FR-01: docs first, failing ordered-navigation regression, minimal state-machine
   extension, then replay regression and minimal replay behavior.
3. ONB-02 / FR-01…FR-15 implemented subset: native feature pages and menu replay, catalog
   translations, synthetic bilingual real-window E2E. Skip from any page; fixed footer;
   no permission/export side effects. Failure: closing an unfinished first-run window does
   not persist completion, and reopening remains usable.
4. Compare safe missing reference capabilities with each existing module, write individually
   actionable tracer-bullet tickets with independent tests, dependencies and stop conditions.
   Implement each unblocked safe slice and attach actual checks; do not close the overall request
   merely after writing tickets. Reject claims that cannot be verified and implementations that
   violate protected boundaries. Unknown proprietary internals remain unverifiable.
5. Stable gates, supplementary beta diagnostics, two-axis adversarial review, corrections;
   independent acceptance. All findings map to fixed/disproved/blocked.
6. Consistent candidate version/build/docs; regenerate project; working-branch commit/push,
   PR/CI, authorized merge and beta tag only after checks meet the candidate contract.
7. Local Developer ID archive/export and rollback-safe installation, verify exact installed
   artifact; preserve existing user documents and application data. Report independent
   installation, runtime, notarization and physical qualification separately.

## Exact gates

Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` throughout stable checks.

- `swift test --package-path Packages/RecortiaKit --filter OnboardingModelTests`
- `scripts/check.sh --unsigned` (or signed gate where authorized identity is available)
- `scripts/e2e.sh --lang all` using synthetic services only
- Xcode 27.2 beta MCP compiler diagnostics/preview for the touched onboarding SwiftUI surface
- Focused `cccc --no-cache --min 0`, reconcile unsupported files and parse failures
- Local archive/export parameters and distribution checks from `scripts/release.sh`

## Artifact and resource constraints

Release blocker discovered during current primary-source verification: installed 27A9275 is
Xcode 27.1 **RC**, despite historical repo prose calling the path stable. Apple identifies it
at https://developer.apple.com/news/releases/?id=10052026g. The pinned gate may run for source
development, but does not satisfy stable-toolchain release qualification. The only other
installed Xcode is 27.2 beta 2 (27B5028f). Do not silently change the pin or install outside
the repository; qualified signing/install/merge delivery remains pending the release gate.

The initial tree is main at 53c4d81, with untracked docs/handoffs preserved. Existing .build is
1.7 GiB and .scratch 1.2 GiB; internal disk has about 16 GiB free. MARCUS_S7 is mounted.
Use incremental existing build paths; do not create bulky copies or clean shared artifacts.
If a fresh build/archive requires >1 GiB of new internal output with <20 GiB free, stop that
operation for the owner's disk-space decision. Small evidence is task-owned and retained only
when cited. No blanket scratch deletion.
