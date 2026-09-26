# Threat model — Recortia v1

**Status:** Proposed security contract; not a completed security audit.  
**Owner:** Maintainer to assign in M0.  
**Distribution assumption:** A direct-distribution, Hardened Runtime-enabled app that is not protected by App Sandbox. Record and review this tradeoff before release.

## Assets and trust boundaries

Sensitive assets are screenshot pixels, recognized text, QR payloads, user clipboard content, chosen file destinations, future upload credentials, and release-signing/update keys. Settings are lower sensitivity but may still disclose user preferences or folder access. The clipboard, receiving applications, exported files, backups, OS services, and update infrastructure are separate trust domains.

Raw pixels may exist in bounded process memory for an explicit capture/edit session. Only the export pipeline may produce a ShareSnapshot; only an explicit user action may send that snapshot to a file, clipboard, drag receiver, or approved future uploader. The default application deliberately persists no capture/OCR archive. OS memory management and external applications are outside that control.

The model covers malicious imported inputs, malicious screenshot/QR text, accidental privacy leaks, compromised dependencies/update paths, and erroneous coding-agent changes. It does not promise confidentiality against a compromised operating system, a malicious process with equivalent privileges, physical observation, or a recipient who already has an earlier unredacted export.

## Threat register

| Threat | Failure path | Required mitigation | Evidence |
|---|---|---|---|
| Insecure redaction | Source survives under blur, transparency, layers, metadata, or an alternate clipboard type | Opaque source replacement; pre-filter masking; new flattened encoding; metadata/type allowlists | RED-01/02/03 |
| Stale derivative leak | Old OCR, magnifier, pin, or delayed export contains masked pixels | Revision + privacy epoch; invalidate dependent caches; check completion identity | RED-03, PERM-02 |
| Wrong-source capture | Display/focus/target changes during selection or scrolling | Stable source token, shared geometry mapping, lifecycle cancellation, app-window exclusion | CAP-01, GEO-01, SCR-03 |
| Resource exhaustion | Huge image, overflow, excessive scroll frames, unbounded undo/cache | Predecode checks, checked arithmetic, explicit area/frame/time budgets, bounded queues | IO-01, SCR-04, PERF-01 |
| Accidental external action | Escape autosaves, QR opens itself, clipboard copied before privacy edits | Side effects only after user action; defaults off; QR review; commit-aware cancellation | OCR-02, EXP-02, RED-04 |
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
