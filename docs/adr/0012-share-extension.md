# ADR-012: A sandboxed Share extension that hands one image to Recortia

**Status:** Blocked (2026-11-21). Proposed by the coordinator at the plan's scheduled ADR stop,
under the owner's 2026-11-20 delegation (`docs/specs/program-2026-11/decisions.md`); it would amend
ADR-002 (one unsandboxed target with no new entitlements). The third and final fresh-context review
still found paths to forbidden outcomes (round 3 in the ledger), and Step 5 rests on system
behaviour only the owner can qualify (Unblock). Nothing is built. The owner decides whether to run
the spike and continue, take the Services-menu alternative, or drop B-4.
**Requirements:** FR-14 (import), Program 2026-11 B-4 · **Verification:** `ShareInboxTests`,
`check-release-entitlements.py` and its tests, bilingual E2E `share-inbox`

## Context

People want to send an image from another app's Share menu to Recortia's editor. On macOS a Share
item comes only from an app extension (`com.apple.share-services`). Facts (sources in
`docs/specs/program-2026-11/evidence/share-extension-facts.md`):

- Every macOS app extension must be sandboxed, even inside an unsandboxed app (Apple DTS, 2025).
- The documented hand-off between an extension and its containing app is an App Group container.
  On macOS 15 and later both sides must claim the group; a group ID that starts with the Team ID
  needs no provisioning profile and shows no access prompt, and a Developer ID profile authorizes
  `TEAMID.*` automatically.
- `NSItemProvider.loadFileRepresentation` deletes its temporary copy when the handler returns;
  `loadDataRepresentation` delivers one complete `Data`.
- Whether a sandboxed macOS extension may open its containing app with `NSWorkspace` is not
  documented (Apple's "not supported" answers are about iOS). It must be qualified on macOS 26.
- Xcode's `exportArchive` signs a nested appex inside out; the appex needs the Hardened Runtime and
  a timestamp to notarize. Gatekeeper runs the extension only after the person opened Recortia once.
- A new Share extension may need the person to enable it in System Settings › General › Login
  Items & Extensions.

## Threat model

- **Adversary.** Another app that offers content to the Share menu; content that is not what it
  claims (a huge file, a non-image with an image type, a dataless cloud file); an older copy of
  Recortia running from another path. Code signed with the owner's own Team ID is trusted: it is
  the owner's code, and the Team-ID group exists to admit exactly that code.
- **Forbidden outcomes.** (F1) the extension's code reads or holds more than Recortia's import byte
  limit, or Recortia reads or decodes a shared image outside `ImageImporter.admit` or beyond the
  import limits Open With already enforces (input bytes, decoded pixels, memory budget); (F2) a
  shared image persists on disk after the hand-off ends, becoming a screenshot archive; (F3)
  Recortia's or the extension's code makes a network request, or the shipped (Release-signed)
  extension carries any entitlement beyond the sandbox and the one group; (F4) a shared image
  reaches an export without the person's action (automatic exports never run for it).
- **Accepted residual.** The image sits in the group container for the seconds between the
  extension writing it and Recortia handling the URL, or until the next sweep if Recortia never
  runs. The system may make its own temporary copy of the offered file while preparing the
  representation, and may download a cloud file the person chose to share; both are the system
  acting on the person's share, not Recortia's code, and the system deletes its copy when the
  handler returns.

## Decision

1. **One small extension target, production only.** `RecortiaShare` (`dev.mvneves.Recortia.Share`),
   `com.apple.share-services`, embedded in the Recortia app and not in the E2E app (so LaunchServices
   sees one handler). Entitlements, exactly: `com.apple.security.app-sandbox` and
   `com.apple.security.application-groups` = [`$(TeamIdentifierPrefix)dev.mvneves.Recortia`]. No
   network, no user-selected files, no keychain. Hardened Runtime on.
2. **The host claims the same group.** Recortia's Release and Debug entitlements add the same
   single `application-groups` value; nothing else changes. `check-release-entitlements.py` requires
   the new exact sets for the app and for the appex, parsed as plists, and keeps rejecting debug
   entitlements; its tests gain planted extras and missing values. ADR-002's "no new entitlements"
   becomes "the keychain access group and this one Team-ID group; the extension is sandboxed".
3. **Exactly one image in.** The activation rule is a predicate that accepts one attachment
   conforming to `public.image`. The extension shows no compose UI beyond a short progress or
   error message.
4. **Bounded copy into the inbox.** The extension requests only a file representation, never a data
   representation. In the provider's handler it checks the file's size from its attributes and
   refuses anything over Recortia's import byte limit before reading a byte; otherwise it copies
   it, reading at most that limit, into
   `<group container>/Inbox/<random UUID>.<png|jpg|heic|tiff>` with permissions 0600, written
   atomically. It keeps no other copy and decodes nothing (decoding is Recortia's job, inside its
   limits).
5. **Then it asks Recortia to open that file.** It calls `NSWorkspace.open([file], withApplicationAt:
   <its containing app>, configuration:)` with `allowsRunningApplicationSubstitution = false` (so a
   running copy of Recortia from another path is never handed the file) and
   `addsToRecentItems = false`. If that call fails or is refused, the extension deletes the inbox
   file and shows "Recortia couldn't receive the image. Open Recortia, then share again." (pt-BR
   too). It never retries in the background.
6. **Recortia imports through the existing door and deletes.** The file arrives through
   `application(_:open:)` like Open With. A URL inside the inbox goes through
   `ImageImporter.admit` and the existing import path, including automatic masking of opened images
   when that is on, and opens in the editor; automatic exports never run for it (it is an import,
   not a capture). The inbox URL handler owns cleanup: it deletes the file on every outcome, before
   any other work when admission refuses it (busy, cancelled, not an image), and as soon as
   admission finishes reading it otherwise, whether the import succeeds or fails.
7. **Sweep.** At launch and before handling an inbox URL, Recortia deletes every inbox file older
   than 5 minutes without reading it; if younger files remain, it sweeps again when the oldest
   turns 5 minutes. On termination (`applicationWillTerminate`, after `shouldTerminate()` allowed
   it) it deletes every inbox file, including one whose import is still reading. Inbox files are never added to Recent items, never opened
   from anywhere else, and never logged by name.
8. **Release pipeline.** `release.sh`'s archive and export keep signing through Xcode
   (`exportArchive`), which signs the appex first; the release checks verify the appex signature,
   Hardened Runtime, timestamp and entitlements, and `check-release-binary.sh` also scans the
   appex for the DEBUG E2E hook. `xcode-security-settings.md` records the new entitlement sets.

## Alternatives

- **The Services menu (NSServices).** No extension, no sandbox, no new entitlement, and the host
  stays one target. Rejected as the delivery of B-4 because a service appears in the Services
  menu, not the Share menu the plan names; it remains the cheaper fallback if Step 5 fails
  qualification.
- **The host watches the inbox while running** (a directory monitor or a Darwin notification),
  instead of `NSWorkspace.open`. Avoids the unconfirmed launch, but only works while Recortia
  runs, adds a second delivery path, and leaves files waiting when it does not. Held as the
  follow-up if Step 5 fails qualification.
- **A `group.` App Group ID.** Needs a provisioning profile for the appex and the host on macOS;
  the Team-ID form needs none.
- **XPC between extension and app.** Apple calls direct app-to-app XPC unsupported without a launchd
  rendezvous; rejected.

## Review ledger

| Round | Finding | Outcome |
|---|---|---|
| 1 | A refused (busy) import leaves the inbox file until a sweep that may never come | Fixed: the handler deletes on every outcome (6) |
| 1 | `NSWorkspace` may substitute an older running Recortia, which never deletes the file | Fixed: substitution off (5) |
| 1 | A same-team process can copy the inbox file | Declined: owner-signed code is trusted (Threat model) |
| 1 | A data representation arrives unbounded before the size check | Fixed: file representation only, size checked before reading (4) |
| 1 | A dataless cloud file is downloaded by the system when shared | Declined: the system fetching the person's chosen file is not Recortia's network use (residual) |
| 1 | `NSWorkspace` adds the file to Recent Items | Fixed (5) |
| 2 | Quit during an import leaves the file; a relaunch within 5 minutes skips it | Fixed: delete all on termination, follow-up sweep (7) |
| 2 | A valid image under the byte limit decodes to a raster over 64 MiB | Reworded F1: the limits are the ones Open With already enforces (bytes, pixels, memory budget); the decoder's pixel and allocation checks apply unchanged |
| 2 | A Debug-signed appex gets `get-task-allow` | Reworded F3 to the shipped Release bundle, which the exact-set gate checks; every Debug build carries it, as the host's does |
| 3 | Force Quit during an import leaves the inbox file until the next launch | Open. Coordinator's view: bounded by the next launch's sweep; not accepted unilaterally, because the written residual covers only a host that never runs |
| 3 | A local APFS snapshot taken during the hand-off keeps the image | Open. Coordinator's view: a system copy like the provider's temporary file; the proposed memory-only IPC fix is a rejected alternative |
| 3 | An older running Recortia with an armed delayed capture captures the new editor and auto-exports it | Open. Coordinator's view: any armed capture tool sees an on-screen editor, as with Open With today; not declined, because the threat model names an older running copy |

Rounds 2 and 3 used a prompt about "ordinary events" with web access off, after the provider's
content filter refused the adversarial wording; they are not full adversarial passes.

## Unblock

1. **Owner spike on a macOS 26 Mac** (about 15 minutes, a throwaway app, not Recortia): a sandboxed
   Share extension whose only action calls `NSWorkspace.open([file], withApplicationAt:)` on its
   containing app, with the app (a) not running and (b) running. Pass: the containing app receives
   the URL in both cases, with no prompt.
2. If it passes, decide the three open round-3 rows (accept them as residual, or change the
   design), then one more review, then build.
3. **Alternative the owner may take instead:** a Services-menu item (NSServices) in the host. No
   extension, no inbox file and no new entitlement; it appears in the Services menu rather than
   the Share menu, so it changes the plan's B-4 scope and is not built without the owner's word.

## Consequences

- **New entitlement surface** on both bundles, checked by an exact-set gate. The signed Release
  build and notarization must be rerun by the owner; the Developer ID profile already authorizes
  `TEAMID.*`.
- **Testing here.** `ShareInboxTests` (naming, permissions, size refusal before reading,
  delete-on-every-outcome, sweep by age) in a Foundation-only module both targets use; the
  entitlement gate tests; the bilingual E2E `share-inbox` scenario feeds inbox files to the
  shipping `application(_:open:)` route with an injected container and checks import, deletion on
  success, on failure and on a busy refusal, the sweep, no automatic export, and refusal of an
  oversized file.
- **Owner qualification (`awaiting_manual_validation`).** The Share menu item in a real app,
  enabling the extension, `NSWorkspace.open` from the sandboxed extension on macOS 26 (Step 5),
  Gatekeeper and notarization of the appex, and that no access prompt appears.
