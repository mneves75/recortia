# Signed in-app updater — FP-024

## Assumptions

The owner approved FP-024 on 2026-10-19 ("3. ok") after being told it adds a dependency, a
signing key and a new network path. EdDSA key custody was deferred ("1. later"), so the key
step is the one open decision; everything else below is the approved default.

Binding constraints from the repository:

- `SPEC.md` §376: Sparkle's documented signing flow, valid update signatures, compatible
  deployment targets, a clear changelog, tamper and failure tests, and **opt-in** automatic
  checks.
- FR-14 (release/update flow) and REL-02; PRIV-01 keeps default installs offline.
- Homebrew stays the primary install and update path. The updater is a convenience for DMG
  installs, never the only way to update.
- One reviewed third-party dependency: KeyboardShortcuts 3.1.0. Sparkle becomes the second.
- No analytics, no profiling, no telemetry, no background archive, no silent install.
- ADR-0001 records Sparkle 2.10.0 and requires a license and notices review.

## Problem Statement

A user who installed Recortia from the DMG learns about a new version only by visiting GitHub.
There is no in-app way to discover, verify and install an update, and the project has no signed
update channel, so a compromised feed or disk image could not be distinguished from a real
release except by re-downloading from the releases page.

## Solution

Integrate Sparkle 2.10.0 as a SwiftPM binary target and drive it from one adapter in
`MacPlatform`, with a single explicit entry point and a signed static feed.

- **Dependency.** `sparkle-project/Sparkle`, version 2.10.0 (2026-09-13), macOS 12+ upstream,
  binary target with the upstream-pinned checksum, resolved in `Package.resolved`. The app's own
  minimum stays macOS 15.0.
- **Entry point.** One "Check for Updates…" menu item in the menu-bar menu. It is the only code
  path that starts a check unless the user turns on automatic checks.
- **Default.** Automatic checks are off. `SUEnableAutomaticChecks` is absent and
  `SUAutomaticallyUpdate` is false, so a fresh install makes no update request ever until the
  user acts. Settings gains an opt-in toggle; when it is off, the app performs no feed request.
- **Feed.** A static `appcast.xml` published with the existing GitHub Pages site at
  `https://mneves75.github.io/recortia/appcast.xml`. GitHub Pages is the only new host; no
  account, token or query parameter is sent.
- **Channel.** Stable releases only. Pre-release tags (`v<version>-betaN`) are never written to
  the appcast, so a beta can never be offered to a stable install.
- **Compatibility.** The appcast declares a minimum system version of 15.0 and arm64-only
  hardware, matching the app. Sparkle filters incompatible items before offering them.
- **Signing.** Each DMG is signed with an EdDSA key at release time and the signature is written
  into the appcast item. The app verifies the downloaded archive against `SUPublicEDKey` and
  refuses anything that does not match. Notarization and stapling remain required, so a valid
  signature without notarization still fails at launch.
- **Payload.** The full notarized DMG is the update payload. No delta updates, no separate
  archive format.

## User Stories

1. As a DMG user, I want a menu item that tells me whether a newer stable version exists.
2. As a privacy-minded user, I want no update request until I ask for one.
3. As a user who opted in, I want the app to check in the background without installing anything
   by itself.
4. As a user, I want a tampered or wrongly signed update to be rejected while my current app
   keeps working.
5. As a user on an unsupported Mac, I want incompatible updates filtered out rather than offered
   and then failing.
6. As the maintainer, I want one documented command that signs a release and writes the appcast,
   with the private key never in the repository, a log, or a CI job.
7. As the maintainer, I want a recovery procedure when an update is found to be bad.

## Implementation Decisions

### Updater adapter

`MacPlatform` owns `UpdateService` (a small protocol in `Features`): `isAvailable`,
`automaticallyChecksForUpdates` (get/set), `checkForUpdates()`, and the last check result for
display. `AppModel` exposes it to the menu and Settings. The E2E run injects a synthetic
implementation, exactly like the other boundaries.

Sparkle is started once, at launch, from the composition root. `SPUUpdater` is created with
`startingUpdater: false` and started explicitly so a failure is observable; a failure disables
the menu item and never blocks the app.

### Info.plist

- `SUFeedURL` = `https://mneves75.github.io/recortia/appcast.xml`
- `SUPublicEDKey` = the EdDSA public key (added by the key ticket; absent until then)
- `SUEnableAutomaticChecks` absent, `SUAutomaticallyUpdate` = `false`
- No `SUEnableSystemProfiling`, no `SUSendProfileInfo`, no installer customizations.

### Release integration

`scripts/release.sh` gains one step after notarization: sign the DMG with `sign_update` and
rewrite `appcast.xml` with the new item (version, build, minimum system version, arm64
requirement, release-notes link, DMG URL, length, EdDSA signature, publication date), newest
item first, keeping the previous items. The key is read at that moment from the owner's chosen
store, never written to disk in the repository, never echoed, and never passed on a command line
that appears in a log. Betas are skipped. The appcast is committed to `gh-pages` and pushed with
the release.

### Failure modes

- **Wrong signature or tampered archive:** Sparkle rejects the item; the installed app is
  untouched and the error is shown in the standard alert.
- **Interrupted download:** Sparkle aborts the update; the app keeps running.
- **Incompatible OS or architecture:** filtered out by the appcast before any download.
- **Feed unreachable:** a manual check reports the failure; no retry loop, no crash.
- **Bad release:** remove the item from the appcast and republish; the previous version is
  already in users' hands because nothing installs without their action.

## Testing Decisions

- `UpdateService` adapter: unit tests with a fake Sparkle boundary for default-off automatic
  checks, explicit check, and the disabled state after a startup failure.
- Info.plist contract: a script control asserting the feed URL, absent automatic checks, false
  `SUAutomaticallyUpdate`, and a well-formed `SUPublicEDKey` when the key ticket lands.
- Appcast generation: a script control on a synthetic item set — ordering, stable-only filtering,
  minimum system version, arm64 requirement and signature presence.
- Native E2E: the menu item exists in EN/PT-BR, the synthetic checker reports "no update" and
  "update available" without network, and a failing check leaves the app usable.
- REL-02 manual qualification on a clean test user: valid update installs; corrupted, wrongly
  signed, interrupted and OS-incompatible updates are rejected; offline launch is unaffected.

## Out of Scope

- Delta updates, beta or nightly channels, App Store distribution.
- Silent download or silent install, and any automatic check that is on by default.
- Sparkle's analytics, profiling or system-profile submission.
- A second feed for betas, or per-architecture feeds.
- Moving Homebrew to the appcast or deprecating the cask.

## Further Notes

- License: Sparkle's own code is MIT, but its `LICENSE` also carries an `EXTERNAL LICENSES`
  section; the notices review must enumerate every bundled component and add them to
  `THIRD_PARTY.txt` before the dependency lands.
- Key rotation is constrained by Sparkle's documented rules: the public key ships inside the
  app, so a rotation needs one release signed with the old key that already contains the new
  one. The exact procedure is written in the key ticket, verified against upstream at
  implementation time, not invented here.
- The EdDSA key is not the Developer ID identity and does not replace notarization.
