# Release record — 0.14.0 (28)

Status: **published** 2026-11-11T20:02:38Z as the latest, non-prerelease GitHub release
[v0.14.0](https://github.com/mneves75/recortia/releases/tag/v0.14.0) and installed on the
maintainer's Mac from the published DMG. Sources and tag are frozen at
`cdffc968b49d09d9303a0ade5aec635358aa6cad`, the squash of PR #40, whose tree
`e8822e377bb6ead8667df756923a27945a1d7328` equals that of the verified branch head `5186294`. This
record is a later documentation-only bookkeeping commit.

| Fact | Value |
| --- | --- |
| Asset | `Recortia-0.14.0.dmg`, SHA-256 `bf8aa72479543123ada95513179d3598ea734be3bc7270bd8520ec16d29603a9` |
| Pipeline | `scripts/release.sh` on the tag, exit 0; output `.build/release/0.14.0/` |
| Gate | Production `scripts/check.sh` in `gate.log`: 540 package tests, 620 translations, `check: all gates passed` |
| Notarization | Accepted; app `5f77380b-9c5c-4453-be95-cfeb55e0dea7`, DMG `3a38be3f-5525-4767-bb42-037728f33e2e` |
| Stapler and Gatekeeper | Pass for the app and the DMG |
| dSYM UUID | `48FCDB8B-AF58-36C0-A1DC-73179968690C` |
| Public download | Anonymous download succeeded; SHA-256 equal to the qualified DMG |
| Security gate | WAIVED (SEC-11, SEC-17, SEC-18, expiring 2026-11-25); no confirmed vulnerability; NV-02 and NV-05 needs-validation; record kept privately under `.scratch/security-gate/cdffc96…/` |
| Independent acceptance | PASS by fresh GPT-6 (Codex) verifiers on tree `e8822e3`: criteria 1–9 and 11 with no findings, then criterion 10 |
| Native E2E | 54/54 per language, 3,388 assertions each, on an unlocked console with no input during the run (idle 71 s → 832 s over 760 s); `.scratch/verify-c10/attempt-2/` |
| Homebrew | Not changed; the separate tap's cask still installs 0.12.4 |
| Local installation | PASS: `/Applications/Recortia.app`, entire bundle `diff -rq` equal to the app in the DMG; strict signature, stapler and Gatekeeper pass; no `get-task-allow`; executable SHA-256 `71da9ca0b7d3e3c270cf847067613239bef100c7ae7fb79f1b0458b91632e3ec`; relaunched from the installed path |
| Previous bundle | 0.13.0 (27) preserved privately under `.scratch/install-0.14.0/`; the earlier instance ended through a normal quit |

Three verifier passes found and closed V-1, V-2 and V-3
([findings](../code-review-2026-11/findings.md#independent-verification-2026-11-11)). Runs voided
by a contended console (another app's keychain prompt, input during the run, a screen lock) are
kept with their readings and count as neither pass nor fail.

Staging and GitHub CI were skipped as for 0.13.0; no staging infrastructure exists, so nothing here
claims a staging or CI result.

Not qualified by this release: the window toolbar on macOS 15 and 26, physical keyboard, Spaces
and displays, live ScreenCaptureKit/TCC prompts, IME, VoiceOver and Full Keyboard Access on the
toolbar and inspector controls. Native E2E uses the DEBUG harness with synthetic frames and sinks.
