# Local installation request — 2026-10-15

The owner requested installation on this Mac after completion, a durable note, and Git
add/commit/push. This authorizes the scoped 0.12.0/build19 candidate's local installation at
`/Applications/Recortia.app` once its required gates pass. It does not authorize a merge,
tag, release, publication, or bypassing qualification gates. The subsequent owner reply
`autorizado` also authorizes installing the reviewed stable Xcode27.0 at
`/Applications/Xcode_27.app`, preserving the existing Xcodes and system selection.

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

## Authorized toolchain preparation

Apple's official release entry confirms Xcode27 (`27A266a`):
https://developer.apple.com/news/releases/?id=09142026h.
Installed `xcodes`2.1.0 also lists the exact stable build. The external SSD was confirmed
mounted, with572GiB available; the internal disk had139GiB available at preflight. The archive
download destination is `/Volumes/MARCUS_S7/ARCHIVE/dev-scratch/recortia/xcode-27-install-20261015`.

`xcodes download 27.0 --no-aria2 --directory <destination>` with noninteractive stdin
exited1 at Apple authentication; no credentials were supplied or extracted. A credential-free
request to the catalog's official Apple archive URL redirected to an HTML account/download
surface, not an XIP payload. No archive or new Xcode bundle was created.

The next protected step is the owner's Apple login/2FA in their own Terminal:

```sh
xcodes download 27.0 --no-aria2 --directory /Volumes/MARCUS_S7/ARCHIVE/dev-scratch/recortia/xcode-27-install-20261015
```

After the archive exists, reuse the recorded toolchain and app-install authorizations. Verify
the Apple-signed archive and exact extracted build, install at the approved path without
selecting it globally, then run the outstanding gates. No password, verification code or
session cookie should be sent to an assistant. Toolchain installation and Recortia
installation remain pending; the existing app and Xcodes are unchanged.
