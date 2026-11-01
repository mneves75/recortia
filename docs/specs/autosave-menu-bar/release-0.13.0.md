# Release record — 0.13.0 (27)

Status: **published** 2026-11-01T21:54:22Z as the latest, non-prerelease GitHub release
[v0.13.0](https://github.com/mneves75/recortia/releases/tag/v0.13.0) and installed on the
maintainer's Mac from the production export. Sources and tag are frozen at
`2858cf13c5798e711be4690c364da535d4b21355`; this record is a later documentation-only bookkeeping
commit.

| Fact | Value |
| --- | --- |
| Asset | `Recortia-0.13.0.dmg`, SHA-256 `20f452cc946628859f2f43df896918c4bc759417d01b88c7c5104a8f8789efad` |
| Pipeline | `scripts/release.sh` on the tag, exit 0; output `.build/release/0.13.0/` |
| Gate | Production `scripts/check.sh` in `gate.log`: 519 package tests (103 + 126 + 252 + 38), 629 translations, `BUILD SUCCEEDED`, `check: all gates passed` |
| Notarization | Accepted; app `2c80f1b9-54f4-4a4c-ac17-048e8d45ab29`, DMG `ebdae866-8a4b-4dfe-8bfe-c1fa24c50430` |
| Stapler and Gatekeeper | Pass for the app and the DMG |
| Artifact contract | 8 tests, exit 0 |
| dSYM UUID | `13D75ECB-AFAC-3C3F-8B42-5FFAF990386B` |
| Public download | Anonymous download succeeded; full bytes and SHA-256 equal the qualified DMG |
| Security gate | WAIVED (SEC-17, SEC-18); record kept privately under `.scratch/security-gate/2858cf1…/` |
| Native E2E | 52/52 per language, `.scratch/e2e/20261101-152335-97907/`, run at `2fee018`, whose entire tree `3a76fd0` is identical to the tagged `2858cf1` |
| Homebrew | Not changed; the separate tap's cask still installs 0.12.4 |
| Local installation | PASS: `/Applications/Recortia.app`, entire bundle `diff -rq` equal to the production export; strict signature, stapler and Gatekeeper pass; executable SHA-256 `03086fe4c6a8ff91637a64a5d9acad839adf38de33a0c0348ea0261f06ef99b3`; running as PID 30057, with OS process, executable and path cross-checked |
| Previous bundle | Preserved privately under `.scratch/autosave-menu-bar/`; the earlier instance ended through a normal guarded quit, with no forced quit or discarded session |

Staging and GitHub CI were explicitly skipped by the owner; no staging infrastructure exists, so
nothing here claims a staging or CI result.

Not qualified by this release: physical keyboard, Spaces and displays, live ScreenCaptureKit/TCC
prompts, real `NSOpenPanel` interaction, IME, VoiceOver and minimum-macOS runtime behavior. Native
E2E uses the DEBUG harness with synthetic frames and sinks. Feature acceptance and the historical
RED and readiness failures are in [validation.md](validation.md).
