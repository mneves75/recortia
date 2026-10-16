# Full-source review — independent acceptance verdict

Frozen criteria: [plan.md](plan.md) "Acceptance", frozen on 2026-10-16 before the final artifact.
Artifact: branch `review/full-source-0.12.2` at `002f8b8` against `main` `5268d48`.

## Final verdict (pass 2, single reverify)

```text
Verdict: PASS
Builder: Claude Opus 5.5 + Codex gpt-6.1-sol xhigh / Claude and Codex / integration and implementation lanes
Verifier: gpt-6-astra / shell, Python, Swift 6.4, Xcode 27.0 / fresh context; model confirmed in its Codex session record
Different model required: yes
Different model used: yes
Criterion 1 — Deterministic fixes: PASS — All 11 regressions exercised; seven production-only revert controls (B-1, B-3, A-2, A-3, D-1, D-3, D-4) failed and passed after restoration.
Criterion 2 — F-1 mitigation: PASS — Bounded retries and typed failures verified; 75 font-parity records matched baseline. No cure claimed.
Criterion 3 — Verification gates: PASS — Independently ran 689 supported tests and baseline failure controls. Audited stable gate passes 720 tests and both builds; documentation/comment-only differences permit carryover. Native E2E passes 48/48 scenarios and 2,247/2,247 assertions per language, with matching bundle provenance. Coordinator drove native E2E; the verifier audited its artifacts.
Criterion 4 — Invariants: PASS — Production diff, assertions, export boundaries, and DEBUG isolation checked; no violations found.
Criterion 5 — Documentation: PASS — Delivered behavior, historical evidence, and qualification limitations remain distinguished.
Criterion 6 — Version and freshness: PASS — 0.12.2/build21 matches generated metadata; freshness gate passed.
Criterion 7 — Deferred proposals: PASS — A-1, B-2, D-2 remain explicitly deferred.
Remaining uncertainty: Hosted CI run 38842296882 on the exact head was coordinator-reported to the verifier (the coordinator fetched it with gh: success). F-1's root cause remains unknown.
```

The verifier recomputed the app-bundle SHA-256 (`2cb9b690…70ff6`) and matched both
`provenance.json` files (commit 002f8b8, stable mode, Xcode 27A266a). Its sandbox cannot launch
native apps, run SwiftPM's nested sandbox or reach the network, so it audited the native E2E and
stable-gate artifacts instead of driving them, and showed that the suites its sandbox cannot run
(pasteboard, OCR, QR) fail identically on a pristine 5268d48 tree. Evidence:
`.scratch/full-source-review-20261015/verify2-evidence/`.

## Earlier passes

- Pass 1 (0ab32d9): FAIL and not independent — the requested different model did not take
  effect in a Claude subagent. Its findings were fixed or mapped (see plan.md "Independent
  verification, pass 1").
- A second Claude subagent with a different model requested also ran as the builder's model and
  stopped as BLOCKED without examining anything; the verification moved to Codex gpt-6-astra.

Not qualified by this verdict: physical keyboard/IME/VoiceOver, TCC prompts, multi-display and
fullscreen Spaces, minimum-macOS runtime, signing, notarization and distribution.
