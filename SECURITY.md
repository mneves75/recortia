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
