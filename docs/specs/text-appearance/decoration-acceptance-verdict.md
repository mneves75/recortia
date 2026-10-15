# Ticket02 independent development acceptance

Target: `2df6387363e789dffadd6bccb09e52337d0a0537`; full comparison base:
`a3ad94e3edd4222444b871312fe74104d2d52c53`. Production source is unchanged from2276817;
the final correction adds native raster observations and snapshots, not product behavior.

Consolidated development verdict: PASS across the independent code/security and native lanes.
The code lane's isolated verdict remains BLOCKED for runtime criterion4; the separate fresh
native lane supplies that actual evidence below. No criterion was waived. Final full-suite
integration and exact-head hosted CI are recorded separately in decoration-review-evidence.md.
This does not accept physical, minimum-OS runtime, signed installation or release qualification.
The subsequent complete integration run is FAIL: English capture-focus initial key ownership
failed before text scenarios (English45/46,Portuguese46/46). This scoped text-appearance PASS
does not close that separate unresolved integration failure; see decoration-review-evidence.md.

## Fresh full code/security reverify

Verdict: BLOCKED (native runtime allocated to the separate lane)
Builder: GPT-6.1 Sol / main and worker implementation contexts.
Verifier: requested GPT-6 Astra/high / independent source, SDK, cccc and focused package tests /
fresh context. Model identities are dispatch configuration, not runtime attestation.
Different model required: yes
Different model used: yes, according to dispatch metadata
Criterion1 — Seven typed values through editing/selection/undo/serialization: PASS.
Criterion2 — Shared actual-style geometry and real export pixels/bounds/emoji/transforms: PASS.
Criterion3 — Background/reset/mixed selection and refusal before mutation/history: PASS.
Criterion4 — Native input/composition/wrapping/zoom/containment: source PASS, runtime BLOCKED in
this lane; fulfilled by the source-blind native criteria1–3 below.
Criterion5 — ShareSnapshot boundary, paired-secret PNG/JPEG, positive controls/masks/magnifiers
and clean metadata: PASS.
Criterion6 — Public macOS15 APIs, typed errors, off-main rendering, safe concurrency: PASS.
Remaining uncertainty: physical/minimum-OS runtime and release gates were not exercised.

Actual independent command:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development swift test --package-path Packages/RecortiaKit --filter 'TextDecorationExportTests|EditorTextDecorationTests|TextAppearanceExportTests|EditorTextAppearanceTests|TextAppearanceTests|AnnotationRendererTests|EditorCanvasRendererTests'`.
All seven selected suites passed, exit0 (verifier exec session4613). The initial outer-sandbox
attempt failed at sandbox_apply; approved escalation retained SwiftPM's manifest sandbox.
Independent cccc1.8.0: seven focused Swift files,320 functions,zero parse errors; maximum
cognitive complexity29 in TextLayout.operation. Metrics did not replace dynamic proof.

## Fresh full source-blind native reverify

Verdict: PASS
Builder: GPT-6.1 Sol / main and worker contexts.
Verifier: requested GPT-6 Astra/high / exec_command, view_image and its own generated reports /
fresh source-blind context; no source, diffs, tests, prior reports or builder images inspected.
Different model required: yes, per verifier's dispatch contract
Different model used: yes, according to dispatch configuration
Criterion1 — Seven localized native choices, selected state, plaintext input and appearances:
PASS — own EN/PT controls and outlined/rectangular/rounded/monospaced native rasters inspected.
Criterion2 — Wrapped Unicode/emoji/RTL painting at displayed25%/200%, composition and editing:
PASS — every native-input and full-viewport image at both zooms for all seven styles inspected
in both languages; actual multiline glyph pixels present. Post-unmark suffix size matches.
Content/marked/selected ranges, width, confirm/cancel, private plaintext paste, deletion and
native grouped undo passed. The missing25% raster finding is fixed as an evidence gap, not a
retrospective claim that a product rendering defect existed at that zoom.
Criterion3 — Selected backgrounds, nil-white/transparent/custom/mixed values, future defaults,
Reset/undo and active-input disabling: PASS — own native outputs and actual images inspected.
Criterion4 — EN/PT compact-dark usability and truthful onboarding without forced permissions
or completion: PASS — normal/compact controls/tour and failure-path cleared canvas inspected;
own reports confirm replay/unfinished-close preservation and zero permission/export requests.
Remaining uncertainty: physical IME, keyboard operation, VoiceOver, macOS15 runtime,
performance and signed/release qualification remain untested.

Actual independent command:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=development scripts/e2e.sh --lang all --only text-decorations,text-font-designs,text-layout-failure,onboarding --unsigned --no-build`.
Exit0, four scenarios/974 assertions/61 PNGs per language. Own fresh evidence:
`.scratch/e2e/20261014-193057/{en,pt-BR}/report.json` and adjacent PNGs. Initial sandbox execution
failed before reports; approved execution succeeded. Exact-path process check found no test
app remaining; the verifier returned its native lease.

## Artifact identity and limits

Host macOS27.2/26B5112a; explicitly selected development Xcode27.1 RC/27A9275, Swift6.4,
SDK27.0, deployment targetmacOS15. The Debug launcher alone is not an identity for all code.
Verifier-recorded SHA-256 values:

- Launcher: `e9700ae6517aae97715b1036b385efe820142babaac4e4196ed8b703b343257f` (before/after).
- Debug code library: `73e2d8c13a75eab5edd14e904ec3df3486173fa29065b08df946db5dd056c801` (during/after).
- Preview library: `5febeb8307b0c620d30d011fcd05554e656256e615cae6d843a957caccf9960a` (during/after).

Both library measurements began after execution started; no prelaunch library measurement is
claimed. The earlier native verdict on2276817 was BLOCKED solely for missing25% raster proof.
One correction and this fresh full reverify resolved it; there was no open-ended verifier loop.
