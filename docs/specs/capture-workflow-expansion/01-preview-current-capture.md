# 01. Preview the current capture

**Status** implemented, awaiting full and native qualification

**Blocked by** Nothing for implementation. Integrate after the current capture and editor stack qualifies.

**What to build** Open and close a larger in-memory preview from the existing thumbnail and retain the original capture workflow.

- [ ] Preview opens a bounded, sanitized render on the thumbnail’s display.
- [ ] The native action is discoverable, and keyboard close leaves the thumbnail available.
- [ ] Input and focus behavior preserve the foreground app.
- [ ] The preview follows capture replacement, suspension, cancellation and the existing timeout.
- [ ] The full unsigned gate and bilingual native checks record actual outcomes, including light and dark screenshots.

The unsigned E2E app build, 17 focused Quick Actions and pin privacy tests, and source review
passed. Native input, pixel reproduction, visual and physical criteria remain unchecked.
