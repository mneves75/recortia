# Ticket01 independent acceptance

Target: f1852b785c2e036e26e187d03da71b1cf2b6185e; comparison base:
2d0acb7afc62735b7452ea8a6189792b397e8fbe. Only Standard/Rounded/Monospaced are accepted here.
The four decorations, complete competitor parity and release qualification are excluded.

## Code and security

Verdict: PASS
Builder: configured gpt-6.1-sol/xhigh / repository tools, SwiftPM, Xcode / main and implementation worker
Verifier: configured gpt-6-astra/high / fresh independent source/security review, SwiftPM, cccc
Different model required: yes
Different model used: yes
Criterion 1 — Legacy metadata and distinct public system fonts: PASS — independent decoding,
transform and exported-pixel regressions; unknown values reject.
Criterion 2 — Editor selection, input, undo and refusal: PASS — selected-text filtering,
creation/duplication/reopen/confirm/cancel, Select All and independent undo; rejected layout
preserves document/style/history and reports the existing notice.
Criterion 3 — Measured geometry and native transport: PASS — exported Unicode/RTL/emoji ink
fits measured frames at 0.75x/2x for all designs; native source carries font and content width.
Criterion 4 — Fail-closed export/privacy: PASS — typed failure prevents snapshot construction,
caller graphics state restores, masked PNG/JPEG positive-control and magnifier/metadata tests
pass. Runtime native canvas clearing is accepted separately below.
Criterion 5 — Restricted AppKit boundary: PASS — exact two font-class declarations and source
path, planted broad/other/malformed/URL bypass controls; no sandbox claim.
Criterion 6 — Scope/side effects: PASS — no new dependency, cache, permission, secret transfer,
network destination or deployment change.
Criterion 7 — Required development checks: PASS — verifier personally ran 41 focused tests
(20 Imaging / 18 Features / 3 Domain), exit0. It read the corrected full gate's 640-test,
two-build, localization PASS; it did not rerun that whole gate.
Remaining uncertainty: configured model identities are not runtime-attested. Physical
IME/VoiceOver/Spaces, macOS15 runtime, stable-Xcode qualification, signed install/release and
actual forced font-unavailability remain unqualified.

Verifier command:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development swift test --package-path Packages/RecortiaKit --filter 'TextAppearanceTests|EditorTextAppearanceTests|TextAppearanceExportTests|QRDecodingTests.imagingSourcesHaveNoSideEffectAPIs|AnnotationRendererTests|EditorCanvasRendererTests|ExportContainerTests|RedactionTests'`

Evidence: `.scratch/text-font-independent-code-20261014/focused-tests-approved.log`.
The initial restricted invocation stopped before testing; approved execution retained SwiftPM's
sandbox. Independent cccc1.8.0 scan: four source files, 86 functions, zero parse errors, exit0.

## Native behavior, source-blind

Verdict: PASS
Builder: configured gpt-6.1-sol/xhigh / separate implementation context
Verifier: configured gpt-6-astra/high / exec_command, view_image, synthetic native AppKit interface / fresh source-blind context
Different model required: no
Different model used: yes
Criterion 1 — Real controls, selected state, undo, future text and Cmd+A: PASS — fresh bilingual
reports and personally inspected Standard/Rounded/Monospaced render states/checkmarks.
Criterion 2 — Native input/font/wrapping: PASS — real NSTextView insertion, reopen, cancel,
confirm, Unicode/multiline, 25%/200% zoom and input-safe disabled controls with help.
Criterion 3 — Render failure clearing: PASS — nine checks per language and personally viewed
blank opaque canvas with localized error.
Criterion 4 — Bilingual standard/minimum dark layout: PASS — full labels, checkmarks and
toolbar within 980x560; actual controls and AX values exercised.
Criterion 5 — Feature tour: PASS — 236 checks per language, replay/Skip/navigation/state and
consent preservation, no external side effects; personally inspected normal/compact editing
pages truthfully describing three fonts.
Remaining uncertainty: synthetic development target only; no physical IME/VoiceOver/Spaces,
minimum-OS runtime, installation or release qualification. Model IDs are configured, not
runtime-attested.

Verifier's own command:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development scripts/e2e.sh --lang all --only text-font-designs,text-layout-failure,onboarding --unsigned --no-build`

Own fresh evidence: `.scratch/e2e/20261014-175854/{en,pt-BR}/report.json`, 358 assertions and
17 images per language, 6.6MB. The judge inspected all font/failure images and both normal and
compact-dark tour editing pages. It read no source, diffs, tests or earlier builder evidence.
Log: `.scratch/text-font-native-independent-approved-20261014.log`. An initial sandbox launch
failed before app execution; that log is retained separately. Recovery used the normal approved
execution route without changing the artifact. Narrow approved process inspection found no
remaining runner. No source or user settings were changed by verification.
