# Security policy

## Reporting a vulnerability

Report privately through GitHub: **Security ▸ Report a vulnerability** on this repository
(private vulnerability reporting). Do not open a public issue for a vulnerability, and never
attach real screenshots, recognized text, QR payloads, or file paths: use synthetic images.

Include the Recortia version or commit, the macOS version and build, and the smallest synthetic
reproduction you can. Reports are acknowledged through the same advisory thread.

## Scope

In scope: anything that lets an exported, copied, dragged, or pinned image carry pixels or metadata
the user redacted; stale OCR, magnifier, or pin results after a redaction; malicious image imports
(crashes, unbounded memory, code execution); app-initiated network traffic; unexpected permission
requests; and release or update integrity.

Out of scope: a compromised operating system or another process with the user's privileges;
copies the user exported before redacting; other applications' clipboard histories; and blur or
pixelate effects, which Recortia labels cosmetic and never secure.

See THREAT_MODEL.md for the full model and ADR-002 for the permission and sandbox tradeoff.

## Supported versions

Only the latest release receives security fixes.

## Lost release device or exposed credential

The maintainer, `@mneves75`, owns incident response through the private vulnerability-reporting
channel above. Release workstations must use FileVault and require authentication immediately
after locking. Never include credentials, personal captures or local paths in an incident report.

1. Stop release publication and distribution updates. From a trusted device, revoke the affected
   GitHub tokens and sessions, Apple sessions and other release access. If a Developer ID private
   key may be exposed, the maintainer assesses certificate revocation and replacement through
   Apple's developer-account workflow before signing again.
2. Review GitHub security/audit logs, repository changes, release assets and Apple-account access
   for the incident period. Identify affected artifacts and recipients; withdraw compromised
   downloads and distribution updates rather than replacing an artifact under the same version.
3. Rotate only affected credentials through the maintainer's approved credential workflow. Scope
   replacement GitHub access to the repositories and permissions actually needed. Restore the
   signing environment on a trusted, encrypted device and retain content-free incident evidence.
4. Review the exact recovery source tree, rerun local tests and the security gate, then build,
   sign and notarize a new version through `scripts/release.sh`. Verify the downloaded artifact's
   checksum, signature and notarization before resuming distribution.
5. Notify affected users through the approved security advisory/release channels. Recortia has no
   automatic updater: users must install the corrected release. Revocation cannot erase screenshots
   or files already exported to another app, disk, backup or GitHub repository.

Credential revocation, publication, certificate changes and user notifications are maintainer
decisions; this runbook does not authorize an assistant to perform them automatically.
