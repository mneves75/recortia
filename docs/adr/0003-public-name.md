# ADR-003: Public name "Recortia"

**Status:** Accepted (owner decision, 2026-09-26)

## Context

The specification used "Framepin" as a provisional codename and stated that name, domain, and
trademark availability were unchecked. A web search before the first public release found
FramePin (framepin.com), a screen-recording tool that turns captures into interactive guides with
callouts, arrows, spotlights, and zoom, and exports screenshots — the same product category — and
Framepin (framepin.co), a filming-locations community.

## Decision

Ship as **Recortia** (from Portuguese/Spanish *recortar*, "to crop/cut out"). A web search found no
product using the name. This is not a legal trademark clearance.

Everything user-facing and structural moved in one commit: app and bundle identifier
(`dev.mvneves.Recortia`), Swift package (`RecortiaKit`), UI strings in both languages, export
filenames, scripts, CI, and documentation. Earlier history and some planning documents record the
old codename.

## Consequences

- Preferences, TCC grants, and login-item state from pre-rename Debug builds do not carry over
  (new bundle identifier). No public build ever shipped under the old name.
- A formal trademark search remains the owner's responsibility before any paid distribution.
