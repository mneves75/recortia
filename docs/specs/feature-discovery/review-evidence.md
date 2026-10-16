# Adversarial review and verification record

## Fixed source target

Implementation commits: `f13e749` (area sampling) and `1b0b83d` (tour/integration/docs).
Baseline: `53c4d81`. Final app metadata: 0.12.0/build 19, intended beta1 label only.
The original broad request remains unfinished; this record accepts no full-parity claim.

## Standards axis (Matt Pocock code-review, fresh context)

- STD-001 / P3: interpolated progress lacked a translator comment. Fixed at the Text call,
  identifying the current-page and total placeholders.
- STD-002 / P2: area-pick task was publication-fenced but not canceled/cleared by close().
  Fixed by invalidateColorPick() at the close cancellation boundary. Source-red lifetime
  regression had four expected failures; green then passed. Completed colors and pending
  task/token ownership now clear on close, and copy is rejected.
- STD-003 / P3: new sample-size picker used a closure Binding despite Apple key-path guidance.
  Fixed with @Bindable and a writable guarded projection. Direct-assignment regression went
  red with six expected failures, then green; closed state cannot change the selection.
- No additional actionable Fowler smell was identified. Complexity is advisory only:
  cccc 1.8.0 analyzed all nine initially selected production files with zero parsing errors;
  the subsequent close-file change is covered by focused review/testing.

## Spec axis (fresh context)

- SPEC-001 / P1: the broad competitor-feature request is incomplete. OPEN: the matrix contains
  safe unfinished capabilities, protected changes and proprietary internals that were not
  verified. Tickets/plans are not implementation. No overall PASS or full parity is claimed.
- SPEC-002 / P2: automatic-export education could imply later redaction repairs an earlier
  copy. Fixed: disable automatic copy/save/upload before sensitive capture; later edits or
  local deletion cannot recall earlier copies, including remote ones.
- SPEC-003 / P2: model-only onboarding E2E could pass with broken buttons/close callbacks.
  Fixed: current public accessibility frames drive actual native window events; Continue,
  Back, final Done, replay Skip, one visible window and progressed unfinished close/reopen
  are checked. No global pointer event or private screenshot is used.
- SPEC-004 / P2: safety/preference observations were incomplete. Fixed: denied Screen
  Recording and Accessibility inputs, original consent identity, a nondefault shortcut,
  export-snapshot count, capture/scroll/upload records, image/text private pasteboards and
  drag deliveries are observed. Fixtures restore their settings after the scenario.

## Deep improve findings

- FD-01: first-export warning: fixed as SPEC-002.
- FD-02: matrix incorrectly called existing editor aspect/Shift constraints missing: fixed;
  missing capture constraints remain a separate row.
- FD-03: feature families are not atomic full-parity evidence: partial correction with line,
  text styles/palette, Auto Balance and capture-specific gaps; the inventory makes no
  exhaustive proprietary-internals claim. Unfinished source slices remain explicit.
- Conservative alternative: qualify current capture/privacy/latency before expanding tools.
  Chosen implementation adds only bounded local sampling and native discovery at this stage.
  Linear-light averaging was considered; explicit encoded-sRGB arithmetic was chosen and
  distinguished by literal fixtures. No perceptual/color-contrast claim is made.

## Actual checks

All commands below use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` unless
stated otherwise. Exact installed build 27A9275 is **Xcode 27.1 RC**, not stable; Swift 6.4,
macOS SDK 27.0/26A425, host macOS 27.2 seed 26B5112a, arm64.

- `scripts/check.sh --unsigned`: exit 0 at 1b0b83d; 589 package tests (134+141+265+49), strict
  format, generated project freshness, both unsigned Debug builds, 578 extracted strings
  with pt-BR translations. `.scratch/feature-discovery-final-check.log`.
- Focused source-red/green: OnboardingModelTests and area sampler/editor suites. Final
  sampler 10 and editor 14 tests pass. `.scratch/area-color-sampling/` logs 02/04/11/14
  prove missing behavior before implementation/corrections; 06/15/16 prove final checks.
- `scripts/e2e.sh --lang all --only onboarding,pixel-tools,capture-focus,editor-presentation --unsigned`:
  onboarding and pixel-tools pass in both languages at final corrected source metadata;
  the other two fail. `.scratch/e2e/20261014-010809/{en,pt-BR}/report.json`.
- `scripts/e2e.sh --lang all --no-build`: 40/42 per language; no failure was removed or
  converted to a pass. `.scratch/e2e/20261014-005816/{en,pt-BR}/report.json`.
- Isolated `--lang en --only capture-focus,editor-presentation --no-build`: same two failures
  without running the tour, 0/2. `.scratch/e2e/20261014-011113/en/report.json`.
- Xcode 27.2 beta MCP: current compiler diagnostics report zero issues in OnboardingView and
  EditorInspectorView. This supplements development checks; no beta distribution is claimed.
- Impeccable context/detector and generated synthetic EN/PT-BR normal/compact-dark views were
  inspected. Native system controls/appearance are retained. No tasteskill package was found.

## Unresolved UI evidence

capture-focus: first responder, explicit targeted Escape/Space/Return and preserved foreground
pass, but isKeyWindow fails. Synthetic injected keys do not establish hardware-key ownership.
editor-presentation: ordered/active-Space/responders pass; inactive occlusion .visible fails
with raw state 8192. AppKit says transparent windows may still count visible, and .visible is
not proof of topmost order. Relevant production paths and those fixtures are unchanged from
53c4d81; indirect/host causes are not fully excluded. A baseline same-host control and an
authorized dedicated desktop are needed before assigning a production fix. Neither assertion
was weakened. Physical keyboard/TCC/Spaces/VoiceOver and performance qualification remain unrun.

## Release stop

[Apple identifies 27A9275 as RC](https://developer.apple.com/news/releases/?id=10052026g).
Only it and Xcode 27.2 beta are installed. The specification requires stable Xcode; the
source gate above is development evidence only. Internal free space is about 14 GiB, so no
bulky fresh archive/checkout was created. No merge, beta tag, signed archive/export, Mac
installation, notarization or publication has been performed for this candidate. The owner
must supply a stable toolchain/authorize an outside-repo toolchain change before that gate.

## Cleanup boundary

## Hosted CI

[Draft PR #16](https://github.com/mneves75/recortia/pull/16) points to the pushed feature branch.
[CI run 38511010581](https://github.com/mneves75/recortia/actions/runs/38511010581) failed before
compilation: runner Xcode build 27A266a at /Applications/Xcode_27.app differs from
TOOLCHAIN.json 27A9275. The gate correctly rejected this mismatch; no pin/check was weakened.
The final documentation-only commit does not change that mismatch. Hosted compilation/tests
have therefore not passed for this candidate.

## Cleanup result

No worktree, simulator or persistent server was created. Existing dependency/build directories
and the preexisting untracked docs/handoffs directory are preserved. Evidence cited above is
retained. scratch clean --dry-run refused these task-owned older nested E2E directories because
they are not directly under .scratch; the guard was not bypassed:
`.scratch/e2e/20261014-003224`, `20261014-003431`, `20261014-003509`,
`20261014-003815`, `20261014-003920`, `20261014-004042`, `20261014-004148`
(about 7 MiB combined). Their removal remains for the owner under the supported cleanup policy.
The temporary PR body was deleted. The task's Xcode-beta workspace was closed; the previously
open unrelated workspace was preserved. The task-owned gh log cache was cleaned after its
failure text was recorded here. No branch/worktree was removed because the branch is unmerged.
