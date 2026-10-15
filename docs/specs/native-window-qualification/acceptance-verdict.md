# Independent native qualification verdict

Fresh source-blind verification inspected the actual JSON reports and control outputs,
without source inspection, GUI access or rerunning failed controls.

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

Evidence paths refer to `.scratch/native-window-review-20261015/`; native reports are retained
there under `native-runs/` after cleanup of the isolated worktree. Historical success is not
current readiness. No final PASS, merge, version bump or release is authorized by this verdict.
