# Threat model — Recortia v1

**Status:** Security contract for 0.9.1 beta. Source review and synthetic regressions cover the
boundaries below; live capture, platform qualification, and notarized distribution remain separate
checks. Signed local-install evidence and its limits are recorded in README.md and BACKLOG.json.
**Owner:** Repository maintainer.
**Distribution assumption:** A direct-distribution, Hardened Runtime-enabled app that is not protected by App Sandbox. The tradeoff is recorded in ADR-0002.

## Assets and trust boundaries

Sensitive assets are screenshot pixels, recognized text, QR payloads, user clipboard content, chosen file destinations, future upload credentials, and release-signing/update keys. Settings are lower sensitivity but may still disclose user preferences or folder access. The clipboard, receiving applications, exported files, backups, OS services, and update infrastructure are separate trust domains.

Raw pixels may exist in bounded process memory for an explicit capture/edit session. Only the export pipeline may produce a ShareSnapshot; only an explicit user action may send that snapshot to a file, clipboard, drag receiver, or approved future uploader. The default application deliberately persists no capture/OCR archive. OS memory management and external applications are outside that control.

The model covers malicious imported inputs, malicious screenshot/QR text, accidental privacy leaks, compromised dependencies/update paths, and erroneous coding-agent changes. It does not promise confidentiality against a compromised operating system, a malicious process with equivalent privileges, physical observation, or a recipient who already has an earlier unredacted export.

A same-user process that lacks Recortia's Screen Recording or Accessibility grant is *not* treated as equivalent: it must not use Recortia as a confused deputy. Because a non-sandboxed app's preferences domain is writable by such a process, side-effect consent (automatic copy/save, the save folder, automatic scrolling) is honored only when the stored blob carries an HMAC seal over a generation counter, keyed by a secret in the data-protection keychain under Recortia's provisioned keychain access group, which other processes cannot create, read, replace, or roll back. An unsealed, mismatched, or older-generation blob loads with that consent off, and Settings says so. Another process can still delete the preferences or the seal, which only turns consent off (fail-safe). If Recortia cannot store a new generation, it attempts to delete the secret to invalidate older seals. Persistent update-and-delete failure remains a platform validation gap described below.

Secure masks cover source pixels twice: the regions bound when the mask is drawn (they follow the content if a layer moves), and, at render time, whatever layer lies under the mask's output rectangle now (a layer added or moved there later), always before any resample or effect. Secure masks are also the topmost output layer, over annotations and callouts. Any layer change while a mask exists advances the privacy epoch, so derived text, QR results, and pins go stale. Automatic export checks freshness against the live editor session. Capture requires Recortia to be excluded as an application and fails otherwise. Drag-out offers follow ADR-004: revocable until the receiver writes the file, never reported canceled once it has.

## Threat register

| Threat | Failure path | Required mitigation | Evidence |
|---|---|---|---|
| Insecure redaction | Source survives under blur, transparency, layers, metadata, or an alternate clipboard type | Opaque source replacement; pre-filter masking; new flattened encoding; metadata/type allowlists | RED-01/02/03 |
| Stale derivative leak | Old OCR, magnifier, pin, or delayed export contains masked pixels | Revision + privacy epoch; invalidate dependent caches; check completion identity | RED-03, PERM-02 |
| Wrong-source capture | Display/focus/target changes during selection or scrolling | Stable source token, shared geometry mapping, lifecycle cancellation, app-window exclusion | CAP-01, GEO-01, SCR-03 |
| Resource exhaustion | Huge image, overflow, excessive scroll frames, unbounded undo/cache | Predecode checks, checked arithmetic, explicit area/frame/time budgets, bounded queues | IO-01, SCR-04, PERF-01 |
| Accidental external action | Escape autosaves, QR opens itself, clipboard copied before privacy edits | Side effects only after user action; defaults off; QR review; commit-aware cancellation | OCR-02, EXP-02, RED-04 |
| Forged consent | Another process rewrites preferences to turn on auto-export to a folder it reads | HMAC seal over a generation, secret in the data-protection keychain; unsealed or replayed consent dropped; bookmarks resolved without mounting | SettingsIntegrityTests, PreferenceSealTests |
| Malicious data as instructions | Screenshot/issue text persuades an agent or future LLM to run commands | Data has no tool authority; strict action allowlists; human side-effect approval | AGENTS.md review; future AUTO/AI suite |
| Unwanted recording/control | Idle stream, hidden screen archive, global event tap, broad permissions | Capture only during explicit session; no Input Monitoring; no broad keylogging; separate auto-scroll consent | CAP-02, PERM-01/02, PRIV-01 |
| Disclosure through diagnostics | Image/OCR/path/QR appears in logs, CI artifacts, crash uploads | Content-free logs; synthetic fixtures; previewable diagnostics; no automatic upload | PRIV-01 |
| File corruption or escape | Implicit overwrite, malicious filename/path, partial save | User-selected destination; safe names; atomic save; no arbitrary path execution | EXP-02, IO-01 |
| Dependency or release compromise | Mutable action/package, fork secrets, malicious update | Locked reviewed inputs; protected release path; signature verification; least privilege | REL-01/02 |
| False security assurance | App claims universal secret detection, erasure, or compatibility | Scope-specific language; explicit unsupported cases; published validation status | RED-04; release review |

## Non-sandboxed build review

This design avoids privileged helpers and assumes the app runs as the logged-in user. Hardened Runtime and TCC do not provide a general filesystem/network sandbox. Mitigations inside the application reduce accidental exposure but cannot prevent all behavior of compromised app code.

ADR-002 must record why a single non-sandboxed target was selected, whether a sandboxed core build was evaluated, which specific automatic-scrolling capabilities are incompatible with the chosen sandbox profile, and whether removing/deferring automatic scrolling would justify enabling App Sandbox instead. The agent must not claim that the tradeoff was tested before M0 evidence exists. A maintainer may select the safer reduced-scope profile through an explicit ADR update.

## Permission policy

Screen Recording is requested only for a user-initiated screen workflow. Accessibility is requested only for optional automatic scrolling and never on first launch. Manual scrolling, basic capture, and imported-image workflows stay independent of that grant. No Full Disk Access, Input Monitoring, Apple Events automation, microphone, camera, contacts, location, or notification permission is required for the core.

Permission denial/revocation is a supported state. Never change operating-system permission stores, auto-run reset commands, retry intrusive prompts endlessly, or advise disabling system protections. A dedicated test user may manually approve/revoke permissions while collecting release evidence.

## Redaction verification standard

RED-01 is the primary information-dependence check: changing pixels entirely inside a securely masked source region must not change the decoded sanitized export, including derivative samples and resampled edges. It is stronger than merely showing that OCR failed to read a word. RED-02 checks the container and alternate-representation boundary.

This is not a theorem that every possible application implementation is secure. Extend the tests whenever a new effect, image importer, encoding format, pasteboard type, document format, or external sink is added. All such changes require security review. Keep source retention in memory, independently reimported duplicates, and earlier external copies distinct from export-artifact confidentiality.

## Release and incident procedure

Signing/update key material must never be available to untrusted PR jobs, coding-agent prompts, or test fixtures. A named maintainer owns credential rotation, release approval, security reports, and removal of compromised published artifacts. Do not claim a public security-contact address exists until the maintainer sets it.

Before v1, document how to stop a compromised update rollout, distribute a corrected signed build, notify users, and rotate the relevant credential without assuming all users can auto-update. Key recovery and updater trust continuity require an actual staging test. For privacy defects, document what kinds of exports may have been affected rather than promising retroactive deletion from recipients.

## Accepted residuals (0.9.1 beta)

### Additional validation gaps from the 2026-09-29 source review

These hypotheses have not been reproduced and are not confirmed vulnerabilities. Production
qualification retains their uncertainty rather than treating source review as proof:

- Keychain update and deletion can both fail. The deletion fallback described above guarantees
  revocation only when deletion succeeds; persistent failure and restart/replay need an injected
  platform test.
- PNG IDAT expansion has an explicit budget; compressed ancillary metadata also needs adversarial
  fixtures to establish ImageIO's allocation behavior.
- Window identity can change between enumeration and capture. A dedicated desktop test must
  establish the behavior if the OS reuses a window ID across owners.

Confirmed corrections in beta3: macOS sharing Stop tears down scrolling and its timers; floating
foreign windows count as target occluders; Release validates the actual Keychain entitlement;
pixel-tool coordinates and loupe bounds use checked integer arithmetic. Synthetic evidence is
recorded in BACKLOG.json and does not substitute for the platform tests above.

### Previously accepted residuals

From the 2026-09-26 audit and independent reviews; each is either availability-only, requires the
user's own action, or needs a platform capability not yet adopted.

| Residual | Why it is accepted now | Path to close |
|---|---|---|
| Debug builds have no keychain access group, so automatic export consent lasts only for the session | Fails closed; Release builds are provisioned | None needed |
| Any process can post `com.apple.screenIsLocked` and cancel a capture or scroll | Fail-safe: it only cancels | Confirm with `CGSessionCopyCurrentDictionary` |
| Scrolling's source-window/focus binding has only synthetic verification | Identity is checked while collecting; each automatic event also checks owner, bounds, and the window under its point | Validate window switching and Recortia focus on a dedicated live-capture desktop |
| Chooser and overlay commits do not carry their request ID | A replaced session's UI can only commit into a session the user started | Bind commits to the active request ID |
| Auto-copy/auto-save is skipped silently while a drag chip is pending | Fails closed | Surface the skipped export |
| Paste and drop read the pasteboard item on the main thread before the 64 MiB check | Explicit user action; own-process availability only | Read off the main actor where AppKit allows |
| A TIFF-only clipboard is read and then refused as unsupported | By design: the bounded importer decodes only PNG and JPEG (FR-03); reading it lets the message say why | Add a bounded TIFF path only with its own validation and review |
| Magnifier callouts can show pixels outside a crop | Visible in the preview; crop is not a privacy control (FR-04) | Clip magnifier sources to the content rect |
| Stored `launchAtLogin`/`updateChecksEnabled` are unused | Never read; the system login-item status is authoritative | Remove the fields |
| Screen Recording loss during region or window selection is found only when the capture call fails | TCC still blocks the capture; the failure is reported | Re-check permission at commit |
| One shared export operation: a pending drag chip (until the receiver writes the file) makes other editors' exports return busy, and the chip does not name its document | Fails closed | Scope busy state per document; title the chip with the document |
| Each automatic-scroll step checks focus and target, not session or lock state | Lock and session-resign notifications stop the session | Check `CGSessionCopyCurrentDictionary` per step |
| A hand-edited `defaultExportScale` may use the whole 0.1…8 range, beyond the UI's 0.5/1/2 | Render and export budgets still bound the cost | Snap to the offered scales |
| Global shortcut assignments (KeyboardShortcuts' preferences and `RecortiaShortcutDefaultsOffered`) sit outside the preferences seal, so another same-user process can assign or revive a capture shortcut | A shortcut only starts a selection or opens the editor; exports still need the user or sealed consent, and Settings shows every assignment (ADR-005) | Drop stored shortcuts without ⌘, ⌃, or ⌥ at launch, or seal the assignments |
| Another app's ordinary hot key on the same keys is not detected, so both apps may react | Carbon reports only exclusive registrations; onboarding and Settings tell users to clear a default another app uses (ADR-005) | None available through public API |
| Scrolling-capture assembly makes transient full copies of the stitched image | Own-process memory, not attacker-amplified | Assemble directly into the final buffer |
| Reopening from the Dock before the menu was ever opened shows nothing | Functional only | Open Settings without the menu's hook |
