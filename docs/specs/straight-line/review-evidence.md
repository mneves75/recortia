# Continuation review and gate evidence

## Frozen source and scope

Base 110f5cd; toolchain separation 91f721a; straight-line feature ab876f4. App remains
0.12.0/build 19, intended beta1 label only. The full reference-feature request is unfinished.
This record supplements the earlier feature-discovery evidence; it does not rewrite past failures.

## Checks run

- `RECORTIA_TOOLCHAIN_MODE=development DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/check.sh --unsigned`:
  exit 0; 602 package tests (134+145+272+51), both unsigned Debug builds, 580 extracted strings
  all translated into pt-BR, format/project checks and Python controls. One release bundled-notice
  check is SKIPPED because it needs an exported bundle. `.scratch/continuation-development-check.log`.
- `scripts/e2e.sh --lang all --no-build` with that explicit development environment: 42/42
  scenarios and 75 screenshots in each language. `.scratch/e2e/20261014-103057/` and
  `.scratch/continuation-full-e2e.log`. The activation-probe positive control is SKIPPED once in
  each language; no physical-activation safety conclusion is drawn from it.
- Scoped native `--lang all --only annotations,onboarding,pixel-tools --unsigned`: 3/3 in
  each language. The toolbar minimum-width regression first failed at 1019 points, then passed
  at 980 using a native compact-control fallback. `.scratch/straight-line-toolbar-red.log`,
  `.scratch/straight-line-toolbar-green.log`, `.scratch/e2e/20261014-102013/`.
- Package focused geometry/editor/render/export/redaction run: 62 tests across 12 suites.
  A temporary mask-ignore mutant failed with 363 assertions; the engine was restored byte-for-byte,
  its original hash checked and its temporary backup deleted. `.scratch/straight-line-20261014/`.
- [Stable-baseline CI at ab876f4](https://github.com/mneves75/recortia/actions/runs/38572478548):
  PASS. [Toolchain-only CI at 91f721a](https://github.com/mneves75/recortia/actions/runs/38570412109):
  PASS. The earlier mismatch is resolved by an exact stable baseline and explicit development
  mode, not by allowing arbitrary toolchains.

Exact local tools: Xcode 27.1 RC 27A9275, Swift 6.4, macOS SDK27.0; host macOS27.2 seed
26B5112a, arm64. These are development checks, not stable-OS release qualification.

## Adversarial review

Spec axis: zero concrete scoped findings. Native labels/shortcut, document-space geometry,
endpoint handles, history, renderer/export boundaries and stable/development separation align.
Standards axis: one P2 finding — finite stored origin/size can overflow when a line is resized.
The public setFrame repro produced six expected failures: document/revision/history changed and
redo was lost. Correction 7efadda validates the resulting line's endpoints and bounds before
assignment; the public rejection preserves document, revision, undo and real redo replay.
Positive controls retain ordinary axis changes and a finite 1e307 resize; a bounds-only overflow
with finite endpoints is also rejected. The final focused 65-test run and standards recheck
passed. `.scratch/straight-line-20261014/22-overflow-atomic-red.log` and
`26-overflow-final-focused-green.log`. No material Fowler smell was identified.

cccc 1.8.0, unchanged config, literal focused file arguments: nine production files, 357 functions,
zero parse errors. `.scratch/continuation-complexity.log`. Metrics are advisory, not a safety gate.
The verifier's first dynamic-argument metrics command was refused by the command guard; a plain
literal invocation succeeded without bypassing the guard.

## Remaining evidence limits

The previous focus/occlusion failures did not recur, but those production paths were not changed;
do not claim a production fix. Physical keyboard, TCC, IME, VoiceOver, Spaces, displays, stable-host
performance, signed archive/export and Mac installation remain unverified. No merge, tag or
release has occurred. Independent code acceptance is separate from source-blind native UI acceptance.
Curved arrows, palettes/presets, horizontal scrolling, rotate/flip and other matrix gaps remain open.

## Corrected source gates

At 7efadda, `scripts/check.sh --unsigned` with explicit development mode passed 605 tests
(134+145+275+51), both builds and 580 translated strings.
`.scratch/continuation-corrected-check.log`.
[Stable-baseline CI](https://github.com/mneves75/recortia/actions/runs/38586128868) passed.
The fresh full E2E did **not** pass completely: English 41/42 (onboarding replay's first-page
assertion failed), pt-BR 42/42. `.scratch/e2e/20261014-120216/` and
`.scratch/continuation-corrected-e2e.log`. No assertion was weakened. Source-neutral diagnostic
detail was added to report immediate/settled step and window visibility; subsequent isolated
onboarding passed in both languages at `.scratch/e2e/20261014-121108/`.
The intermittent full-run failure remains unresolved; isolated passes are not a production fix.
