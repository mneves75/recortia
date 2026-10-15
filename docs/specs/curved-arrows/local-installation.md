# Local installation request — 2026-10-15

## Current result after the owner's download

**Xcode is installed; Recortia replacement is blocked by current native failures.**
The earlier state below is historical and is superseded by this section.

The owner downloaded the Apple-signed `Xcode-27.0.0+27A266a.xip` (2,014,229,334 bytes) to
`/Volumes/MARCUS_S7/ARCHIVE/dev-scratch/recortia/xcode-27-install-20261015/`.
`pkgutil --check-signature` verified Apple Software signing. `xip --expand` extracted into
the task-owned `/Applications/.recortia-xcode27-install-20261015`; exact version/build and
`codesign --verify --deep --strict` passed before moving to `/Applications/Xcode_27.app`.
The empty staging directory was removed. `xcodebuild -checkFirstLaunchStatus` and
`scripts/doctor.sh --release` pass. Existing Xcode27.1 RC and27.2 beta remain intact;
global `xcode-select` still points to `/Applications/Xcode-beta.app/Contents/Developer`.
No credentials were supplied to the assistant.

Source is `cf877963a49fdef461a07cad068514c282fc5ed5` (implementation `3db91b7`, later
documentation only), built from clean detached `.scratch/wt-local-install-20261015`.
All commands explicitly selected `DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer`.

- `RECORTIA_TOOLCHAIN_MODE=stable scripts/check.sh`: exit0,683 tests
  (134 MacPlatform/167 Imaging/320 Features/62 Domain),617 translations, strict formatting,
  project freshness, scanner/isolation controls and both signed Debug builds.
- `RECORTIA_TOOLCHAIN_MODE=stable scripts/e2e.sh --lang all --no-build`: exit1,
  **45/47 scenarios per language**,2217 assertions and138 PNGs each. Both languages fail
  `capture-focus` keyboard ownership and `editor-presentation` inactive editor occlusion.
  Activation controls skip; that alone does not explain the failures. Earlier green/idle
  runs do not erase these current FAILs. CAP-01 remains unresolved.
- Release archive and Developer ID export: both exit0, using the exact archive/export
  arguments and ExportOptions from `scripts/release.sh`, with isolated task build directories,
  frozen Package.resolved and no tag/notarization/publication. Xcode logged a stale-account
  warning but exported using installed signing material; no credential repair was attempted.

Retained artifact directory:
`/Volumes/MARCUS_S7/ARCHIVE/dev-scratch/recortia/local-install-0.12.0-build19-20261015-cf87796`.
It contains `Recortia.xcarchive` with matching dSYMs, `export/Recortia.app` and
`native-e2e-20261015-014055/{en,pt-BR}` reports/images. Logs, exact ExportOptions and the
export manifest are in `.scratch/local-install-readiness-20261015/`.

Main-session artifact checks pass:0.12.0/build19,arm64,min15.0; strict Developer ID
signature/teamQ96FUTC5G8 and Hardened Runtime; parsed exact Keychain group and no debug
entitlements; valid matching embedded profile (expires2044-09-21); no test-only Mach-O
markers; both licenses match reviewed source and the locked dependency. The profile permits
the exact app entitlement through its team wildcard. An initial ad hoc equality assertion
mistakenly expected an exact profile group; corrected compatibility checking passes.
Export has59 entries/33 regular files. Executable/dSYM UUID:
`1FB063A5-4886-38C0-9003-6CF1150B7695`; executable SHA-256:
`c4aecb8207593e0b80afc30a3312683644116a4fc963829600b4067c8556664b`.

Independent different-model artifact verification passes: metadata, strict signature/runtime,
profile/entitlements, locked dependency/licenses, binary isolation and matching dSYM UUID.
A copied pristine app passes signature verification; mutating a sealed resource fails.
Three invalid entitlement controls are rejected. The installed0.11.0/build18 still matches
all30 independently captured baseline entries (bytes, modes and symlinks); strict signature
passes. Observations are retained in
`.scratch/local-install-verifier-20261015/{artifact-observation,controls-and-preservation}.json`.
Fresh different-model readiness assessment is **FAIL** on current native acceptance; see
`.scratch/local-install-verifier-20261015/stable-native-readiness-addendum.md`.
`/Applications/Recortia.app` remains0.11.0/build18; no app launch, termination, replacement,
document/settings modification or TCC change occurred.

The owner's installation request was conditioned on completion. The specific contract
separates artifact/local-install evidence from UI/notarization; it does not waive required
native E2E or `IMPLEMENTATION_PLAN.md:17`'s CAP-01 candidate-delivery block. Substitution needs
a verified correction/disproof, or explicit owner authorization to install this test candidate
despite the named current FAILs. Preserve the old bundle and independently audit process
identity before any later replacement. Physical input/Spaces/VoiceOver/TCC, clean-user launch,
stable-host performance and distribution remain unqualified on this seed macOS host.

Cleanup: the task-owned worktree and1.25GB of isolated builds were removed after independent
inspection and hash comparison of all354 externally copied native-evidence files. The archive,
dSYMs, exported app and94MB external evidence remain available. The owner's XIP is retained.
No shared cache or preexisting build output was removed; unrelated `docs/handoffs/` is preserved.

## Historical state before the owner's completed download

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
