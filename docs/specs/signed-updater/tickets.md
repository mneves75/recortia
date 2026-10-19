# Tickets: signed in-app updater (FP-024)

Five tickets, in order. T3 is blocked on the owner's key-custody decision; T4 and T5 cannot
complete without it. One commit per ticket, each with its own tests.

---

## T1 — Dependency, license review and pin

Requirement IDs: FR-14, REL-02.

Deliver: `sparkle-project/Sparkle` 2.10.0 (2026-09-13) as a SwiftPM package in
`Packages/RecortiaKit/Package.swift`, resolved and pinned in `Package.resolved`; the binary target
checksum recorded; every license in Sparkle's `LICENSE` and its `EXTERNAL LICENSES` section
enumerated in `THIRD_PARTY.txt`; the ADR dependency table updated with the reviewed version,
commit and license outcome.

Acceptance:

1. `Package.resolved` pins 2.10.0 with its revision and checksum; no floating range.
2. `THIRD_PARTY.txt` lists Sparkle and every bundled component with its license text source.
3. The app still builds for stable Xcode 27.0 with the package added, and `scripts/check.sh`
   passes its dependency and build gates.
4. No Sparkle symbol is referenced yet; the dependency alone changes no behavior.

Focused verification: `scripts/check.sh --unsigned`; `git diff Package.resolved`;
`swift package --package-path Packages/RecortiaKit show-dependencies`.

---

## T2 — Updater adapter, menu item and opt-in setting

Requirement IDs: FR-14, PRIV-01, REL-02.

Deliver: `UpdateService` protocol in `Features`; a `SparkleUpdateService` in `MacPlatform` that
starts `SPUUpdater` with `startingUpdater: false` and reports a startup failure; a synthetic
implementation for the E2E run; "Check for Updates…" in the menu-bar menu; an opt-in
"Check automatically" toggle in Settings, default off; localized EN/PT-BR strings and
accessibility labels.

Acceptance:

1. A fresh install performs no update request: with the toggle off, no feed request is made at
   launch, on capture, or on any path other than an explicit "Check for Updates…".
2. "Check for Updates…" reports "no update", "update available" and "check failed" through the
   native alert, in EN and PT-BR.
3. A failed updater startup disables the menu item and never blocks launch, capture or export.
4. `Info.plist` carries `SUFeedURL`, has no `SUEnableAutomaticChecks`, has
   `SUAutomaticallyUpdate` false, and no profiling key; a script control asserts all four.
5. The E2E run uses the synthetic service and touches no network.

Focused verification: `swift test --package-path Packages/RecortiaKit --filter UpdateService`;
the `Info.plist` script control; native E2E `updater` scenario in EN and PT-BR.

---

## T3 — EdDSA key, custody and public key in the build (BLOCKED)

Requirement IDs: FR-14, REL-02.

Deliver: one EdDSA keypair generated with Sparkle's `generate_keys`; the private key stored in
the owner's chosen store and never in the repository, an argument, or a log; `SUPublicEDKey` in
`Info.plist` with the public key; a written signing-and-rotation procedure in
`docs/specs/signed-updater/key-custody.md`; the recovery path when the key is lost.

Acceptance:

1. The public key in the built app matches the key used to sign a test archive.
2. The private key is absent from the repository, the build products and every log; a scan of
   the release log and the git tree finds no key material.
3. The procedure signs, verifies and rotates a test release without the key appearing in shell
   history.
4. Losing the key is documented as unrecoverable, with the rotation release described.

Status: **blocked**. The owner deferred the custody choice on 2026-10-19 ("1. later"). Options
presented: 1Password `Molty` vault read at sign time (recommended) or this Mac's login Keychain.

---

## T4 — Release integration: sign, appcast, publish

Requirement IDs: REL-02.

Deliver: a step in `scripts/release.sh` after notarization that signs the DMG with
`sign_update`, writes or updates `appcast.xml` (newest first, previous items kept, stable only,
minimum system version 15.0, arm64 requirement, release-notes link, length and signature), and
publishes it with the release; a dry-run mode that builds the appcast from a test key without
touching the live feed.

Acceptance:

1. A release produces an appcast item whose `sparkle:edSignature` verifies against the app's
   `SUPublicEDKey`.
2. Beta tags never appear in the appcast.
3. The appcast keeps older items, newest first, and the live feed parses with Sparkle's own
   validation.
4. No key material appears in the release log; the step fails closed with a clear message when
   the key is unavailable.
5. Publishing the appcast to `gh-pages` leaves the site's existing pages intact.

Focused verification: appcast generation control on synthetic items; a signed test release
verified with `sign_update --verify`; `curl` of the published feed.

---

## T5 — Qualification: tampered, interrupted, incompatible, offline

Requirement IDs: REL-02, PRIV-01.

Deliver: the REL-02 evidence on a clean test user, including a valid update install, a corrupted
archive, a wrongly signed archive, an interrupted download, an OS-incompatible item and an
offline launch; a note in the spec's acceptance evidence and the release gate record.

Acceptance:

1. A valid signed and notarized update installs and the app launches afterwards.
2. A corrupted or wrongly signed archive is rejected and the installed app still runs.
3. An interrupted download leaves the installed app untouched.
4. An item requiring a newer macOS or arm64 is filtered out and never offered.
5. With the toggle off and the network down, the app behaves exactly as before.
6. The security gate runs on the resulting tree before any release, because the network path is
   new.

Focused verification: manual REL-02 checklist on a clean user; the gate record for the tree.
