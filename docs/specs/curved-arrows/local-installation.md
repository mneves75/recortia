# Local installation request — 2026-10-15

The owner requested installation on this Mac after completion, a durable note, and Git
add/commit/push. This authorizes the scoped 0.12.0/build19 candidate's local installation at
`/Applications/Recortia.app` once its required gates pass. It does not authorize a merge,
tag, release, publication, toolchain installation, or bypassing qualification gates.

## Actual state

- Tested implementation: `3db91b7`; accepted documentation head before this note: `0adc68c`.
- Source remains on `feat/onboarding-feature-guide`; PR16 is open and draft.
- Exact-source stable CI passed runs38660460749 and38662049973.
- Local development acceptance:683 package tests,617 translated strings, both unsigned builds,
  independent code/security and bilingual native feature acceptance. See [acceptance](acceptance-verdict.md).
- Capture-focus remains unresolved. The idle run passed100/100 synthetic repetitions, but
  real activation controls skipped and physical/Space evidence remains incomplete. Earlier
  failed runs are preserved; the independent idle verdict is BLOCKED.
- `/Applications/Xcode.app`: Xcode27.1 RC (`27A9275`).
- `/Applications/Xcode-beta.app`: Xcode27.2 beta (`27B5038j`).
- Neither is the reviewed stable baseline Xcode27.0 (`27A266a`).
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/doctor.sh --release`
  rejects the toolchain. Log: `.scratch/local-install-readiness-20261015/release-doctor.log`.
- Installed app:0.11.0/build18, bundle `dev.mvneves.Recortia`, Developer ID team `Q96FUTC5G8`.
  `codesign --verify --deep --strict /Applications/Recortia.app` passes; Hardened Runtime is
  present. No process with that installed executable path was found during the scoped check.

## Outcome and next eligible actions

Installation is **BLOCKED**, not performed. No archive/export, bundle replacement, app restart,
tag or release was attempted. No installed app data, TCC or Keychain contents were read or
changed. The existing app remains intact.

Provide the reviewed stable toolchain and complete the outstanding capture qualification.
Then reuse this owner authorization: archive and Developer ID-export with the repository's
reviewed settings, verify version/build, signature, Hardened Runtime, embedded profile and
parsed Keychain entitlements, reject `get-task-allow`, preserve the previous bundle and running
session, install the exact export, and independently verify provenance and installed hashes.
Record local installation separately from notarization, clean-user launch and production.

Only this task-owned note is staged. Existing untracked `docs/handoffs/` is unrelated and is
preserved. No version bump represents an installation.
