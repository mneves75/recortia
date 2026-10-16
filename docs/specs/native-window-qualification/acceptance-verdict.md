# Independent native qualification verdicts

## Final resumed source acceptance

```text
Verdict: PASS
Builder: GPT-6 main + gpt-6.1-sol helper / stable Xcode 27 gates and native E2E CLI / executable source at380a029
Verifier: gpt-5.6-sol / source-blind E2E CLI, reports, synthetic renders, plist/hash checks / fresh independent context
Different model required: yes
Different model used: yes
Criterion 1 — Owned foreground positive control: PASS — ready, active, foreground, key, visible and active-Space host confirmed.
Criterion 2 — Capture-focus inactive path: PASS — real overlay retained the owned foreground PID while obtaining key-window/responder ownership in both languages.
Criterion 3 — Capture activation and makeKey sensitivity: PASS — omitted-call mutant failed; restored and cooperative activation controls passed.
Criterion 4 — Real editor controller: PASS — hosted canvas, minimization/reopening and opaque-cover negative control passed bilingually.
Criterion 5 — Editor ordering sensitivity: PASS — omitted-ordering mutant failed; restored inactive ordering and cooperative key/responder controls passed.
Criterion 6 — Oracle integrity: PASS — activation, PID, key, responder, visibility, occlusion and Space observations were separate;50 cycles passed per language without skips.
Criterion 7 — Safety/install boundary: PASS — inspected renders were synthetic; installed0.12.0/build19 and its executable hash remained unchanged.
Criterion 8 — Version/project truth: PASS — generated artifact and README report0.12.1/build20; project freshness passed.
Criterion 9 — Final local gates: PASS — stable unsigned gate passed683 tests/617 translations; full native each47/47,2222 assertions/138 PNGs; independent focused each3/3,265 assertions and2 PNGs.
Criterion 10 — Independent acceptance: PASS — criteria frozen before artifact access; no source/diff/tests/builder notes/personal desktop inspected. Exact-head CI is a separate main-owned merge gate.
Remaining uncertainty: physical shortcut/TCC, multi-display/fullscreen Spaces, minimum-macOS runtime, signing/notarization and production installation remain outside this synthetic acceptance.
```

Evidence root: `.scratch/native-window-resume-20261015/`. Full native reports are retained
under `native-runs/20261015-161900/{en,pt-BR}/`; verifier reports under
`native-runs/20261015-162537/{en,pt-BR}/`. The logs are `full-check.log`, `full-native.log`
and `independent-native.log`. All required controls passed; no correction round was needed.
The verifier's capture wrapper was interrupted after both language commands finalized with
exit0 and no app/host process remained (outer wrapper130); this is distinct from native results.
The ordinary main full-suite command itself exited0.

The final behavior judge was explicitly selected as a different model under `mneves-verify`;
the separate Standards/Spec code review remains Sol6.1. The earlier routing/readiness blocker
below is historical and is not rewritten as a pass. Merge completion is recorded by PR16
and `.scratch/native-window-resume-20261015/integration-result.json` after final CI.

## Earlier blocked investigation

Fresh source-blind verification inspected the actual JSON reports and control outputs,
without source inspection, GUI access or rerunning failed controls.

```text
Verdict: BLOCKED
Builder: GPT-6 main + gpt-6.1-sol helper / implementation tools / builder contexts
Verifier: gpt-6.1-sol / read-only shell and JSON/log inspection / fresh context
Different model required: yes
Different model used: no
Criterion 1 — Owned foreground control establishes active/key/foreground/visible state: BLOCKED — latest `host-ready-recheck.json` reports ready/active/key/foreground false, despite visible and onActiveSpace true.
Criterion 2 — capture-focus preserves the owned foreground PID and panel key ownership: BLOCKED — reports `20261015-120618/{en,pt-BR}` and `20261015-120747/en` stop at fixture sequence 0, before product behavior.
Criterion 3 — editor-presentation discriminates opaque overlap and rejects omitted ordering: BLOCKED — the same reports stop before this control; no screenshots were generated.
Criterion 4 — Final stable gate, full bilingual native acceptance and exact-head CI permit merge: BLOCKED — focused runs passed zero of two scenarios; final-candidate gates remain pending. The verifier also matches the helper model, so contested-work different-model acceptance is unmet under the current host review policy.
Remaining uncertainty: the graphical session does not supply a known-good foreground control. These artifacts do not distinguish a product defect from an execution-environment failure.
```

Evidence paths refer to `.scratch/native-window-review-20261015/`; native reports are retained
there under `native-runs/` after cleanup of the isolated worktree. Historical success is not
current readiness. No final PASS, merge, version bump or release is authorized by this verdict.
