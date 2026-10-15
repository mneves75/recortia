# FP-034 independent development acceptance

Code candidate: `3db91b7c8ef1840c657df2853ede6a86718bde0d`.
Comparison base: `03c2a67aa7367c035c385ea166f298303663890a`.
Acceptance comes from the approved [spec](spec.md), with physical qualification and release
excluded. The initial independent FAIL and its correction remain in [review evidence](review-evidence.md).

## Code and security

Verdict: PASS
Builder: GPT-6 / Codex / implementation context
Verifier: configured gpt-6-astra/high / Codex tools, SwiftPM, cccc / fresh independent context
Different model required: yes
Different model used: yes

- Legacy straight JSON/rendering and optional-control round-trip: PASS.
- Creation/default, visible midpoint, selected/mixed state and independent Undo: PASS.
- Endpoint/frame/move/duplicate geometry and cancellation/history preservation: PASS.
- Invalid geometry/style/input/closed-editor refusal before mutation: PASS.
- Shared painted ink, connected head, alpha and sanitized PNG/JPEG exports: PASS.
- Masks/magnifiers, paired-secret equality and unmasked positive controls: PASS.

The fresh full reverify passed 67 tests (24 Imaging/privacy, 41 Features, two Domain) with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development swift test --package-path Packages/RecortiaKit --filter 'CurvedArrow|EditorGesture|EditorComposition|EditorEditing|EditorCommand|Redaction|ExportContainer'
```

Exact command and criterion-level verdict:
`.scratch/curved-arrows-final-acceptance-20261014/verdict-final.md`.
Native numeric/localization/rendering criteria are owned by the separate native lane below.
All five confirmed findings are fixed with fresh regressions: collinear frame admission,
canvas expansion, refused gesture/creation adjustment preservation, and duplicate admission.
Extreme-coordinate framework resource usage remains unmeasured; no performance qualification
or reproduced resource-exhaustion defect is claimed.

## Native and integration

Verdict: PASS (native feature criteria)
Builder: GPT-6 / Codex / implementation context
Verifier: GPT-6 / Codex runner and image tools / fresh source-blind native context
Different model required: no
Different model used: no

All six frozen native criteria pass on `3db91b7`: bilingual Straight/Curved and mixed/future
feedback; real consecutive native Bend X/Y commits; explicitly synthetic endpoint/bend gestures,
Undo/Redo and Escape-equivalent cancellation; readable compact dark controls and actual 25%/200%
curve pixels; disabled controls preserving marked native input; truthful bilingual onboarding.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development scripts/e2e.sh --lang all --unsigned --no-build --only curved-arrows,onboarding
```

Fresh run `.scratch/e2e/20261014-213826/` passed two scenarios, 395 assertions and 25 images per
language, exit zero. The verifier independently inspected both languages' generated renders.
Final full integration on that same rebuilt binary passed 47/47 scenarios, 2,217 assertions
and 138 images per language at `.scratch/e2e/20261014-213931/`, runner exit zero:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development scripts/e2e.sh --lang all --unsigned --no-build
```

Independent native verdict: `.scratch/curved-arrows-native-final-20261014/verdict.md`.
Integration report: `.scratch/curved-arrows-native-final-20261014/integration.md`.
The executable/dylib SHA-256 values stayed unchanged across both runs. Capture-focus's host
activation positive control was skipped in both final languages. Editor-presentation passed
in both final languages, but no root cause or fix of the historical CAP-01 failure is claimed.

The complete local gate on `3db91b7` passed 683 tests,
617 translated strings, doctor/isolation and release guards, strict formatting, generated-project
freshness and both unsigned builds. Command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development scripts/check.sh --unsigned
```

Log: `.scratch/curved-arrows-main-20261014/duplicate-corrected-full-check.log`.
Environment: macOS 27.2 (`26B5112a`), Xcode 27.1 RC (`27A9275`), Swift 6.4/macOS SDK 27.0;
development qualification only. Stable Xcode 27.0 CI also passed on the exact source:
https://github.com/mneves75/recortia/actions/runs/38660460749.

Full baseline on `08ec884` passed 47/47 scenarios per language, 138 images each, at
`.scratch/e2e/20261014-212335/`, runner exit zero. Capture-focus activation control was
explicitly skipped in both languages; editor-presentation keyboard qualification was skipped
in English. Those skips and the historical unattributed CAP-01 failure remain qualification
gaps. Passing integration scenarios do not erase them.

FP-034's approved development completion contract is satisfied. The completed local ticket is
removed; the spec remains tracked. No tag, installation, notarization, merge or release occurred.
