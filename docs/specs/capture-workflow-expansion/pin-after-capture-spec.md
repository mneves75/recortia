# Pin after capture

FR-01, FR-06, FR-07 and FR-09. This implements the local Pin option in [section 3 of the plan](plan.md).

- Settings › Capture › After a capture offers **Pin the capture**. Opening the editor stays the default for older preferences. This choice applies to ordinary still captures. Automatic masking always routes to the editor, including when masking fails. Capture Text, scrolling and import keep their own routes.
- A completed capture fixes its presentation and existing automatic export plan before suspending. Pin uses the existing Copy, Save and separately consented upload order. The selected steps recheck their own live consent and destinations. Pin adds no save, copy, upload or permission prompt.
- The capture owner retains the source pending the batch and pin render. A ready pin contains only the sanitized raster and releases its source pixels. A render or budget refusal leaves the same capture open in the thumbnail, with the reason and Open in Editor available. The fallback does not repeat the batch.
- The automatic pin opens as a normal, switchable window on all Spaces while leaving the foreground application and keyboard focus in place. Explicit Pin actions keep their existing focus behavior.
- Replacing or canceling a pending capture presentation invalidates all pending publication. Screen lock, display changes, sleep and Close All Pins also cancel pending pins. The workflow checks Screen Recording permission before delivery and again after suspension. A revoked grant prevents new automatic deliveries and pin publication. An already admitted sink can finish under its existing contract.

## Verification

Use the quick-action model and synthetic native capture seams to exercise an automatic batch, stale capture completion, permission loss, pin refusal and source release. The native check lets an owned test app take the foreground while the export waits, then checks that the ordinary pin appears without taking the foreground or becoming key. A separate scenario confirms automatic masking still opens the editor. Physical Space switching and live permission checks require the dedicated desktop.
