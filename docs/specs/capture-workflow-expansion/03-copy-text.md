# 03. Copy recognized text

**Status** ready-for-agent

**Blocked by** 01, to share the verified thumbnail lifecycle and native control surface.

**What to build** Offer **Copy Text** for the current capture using on-device recognition over the sanitized revision.

- [ ] Publish correctly ordered local text only after the explicit action and successful recognition of the still-current capture.
- [ ] Empty or cancelled results, privacy refusal and stale callbacks leave the clipboard unchanged.
- [ ] Masked pixels cannot reach recognition. The action creates no saved text, new capture or external transfer.
- [ ] Verify the native action label and outcome in English and Brazilian Portuguese, including accents and failed/cancelled cases.
