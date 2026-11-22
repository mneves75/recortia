# 01. Preview the current capture

**Status** implemented, with bilingual synthetic native qualification. The physical small-capture,
VoiceOver and installed-app checks remain open.

**Blocked by** Nothing for implementation. Integrate after the current capture and editor stack qualifies.

**What to build** Open and close a larger in-memory preview from the existing thumbnail and retain the original capture workflow.

- [x] Preview opens a bounded, sanitized render on the thumbnail’s display in the synthetic native scenario.
- [x] The action opens the native preview and keyboard close leaves the thumbnail available.
- [x] Input and focus behavior preserve the owned foreground fixture.
- [x] The preview follows capture replacement, suspension and cancellation.
- [ ] Observe an open preview close at timeout. The package suite verifies the shared thumbnail
  timer; the native scenario covers replacement, suspension and cancellation.
- [x] The unsigned gate and bilingual native checks record actual outcomes, including light and dark screenshots.

On `6ac344b`, the unsigned hosted gate and bilingual native suites passed. Independent review
inspected light and dark renders and measured the larger native fixture. The small-capture size
correction passed source review. Physical mixed-display, keyboard, VoiceOver and installed-app
checks remain open. The latest receipts are in [progress.md](../../../progress.md).
