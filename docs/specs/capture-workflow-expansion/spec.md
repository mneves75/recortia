# Quick capture preview

## Problem statement

The quick-action thumbnail is too small to confirm details in a capture. Opening the editor starts a separate workflow when the user only needs a closer look before deciding what to do.

## Solution

Add **Preview** to the current quick-action thumbnail. A larger in-memory preview opens on the same display. The user can close it and continue with the same capture and actions.

## User stories

1. As a screenshot user, I want to inspect the current capture at a readable size so I can decide whether to keep it.
2. As a keyboard or VoiceOver user, I want a labeled Preview action and a way to close it and resume the thumbnail actions.
3. As a user working in another app, I want Recortia to keep that app in the foreground while the preview appears and disappears.
4. As a user replacing a capture, I want the surfaces hidden during selection and the earlier preview restored only if I cancel and its capture is still held.
5. As a user inspecting a sanitized capture, I want the preview to contain only pixels the existing renderer would show from that capture.
6. As a user inspecting a large capture, I want preview sizing and memory bounded by one panel and a downsampled render.

## Implementation decisions

- Start from the approved 0.15 candidate, in a separate branch. Its qualification remains the integration dependency. A preview belongs to an existing quick-action capture identity. It does not create another image-store asset, document, archive, file, or export.
- Use the existing sanitizing renderer upon explicit request. Cap the raster at 1,600 pixels on its longest side and preserve native resolution for smaller images. Display the raster at its native pixel density or twice the thumbnail’s displayed size, whichever is larger and fits the display’s usable frame. Magnification uses the same sanitized raster. Keep one expanded render. Stale, cancelled or failed work must never publish pixels, take focus, or alter the current capture.
- Use a nonactivating panel at the existing quick-action window level and Space policy. Opening the preview must not activate Recortia or change the key window. Escape closes the active preview through the keyboard route from the thumbnail or from the preview after the user focuses it. Closing the preview leaves the capture and its actions available. Do not reclaim focus if another app or Recortia window has since taken it.
- The existing eight-second inactivity timer owns both surfaces. Pointer presence over either surface, explicit key focus in the preview and a preview render in progress pause it. Leaving both surfaces restarts the existing timeout. Key focus in the thumbnail alone retains its current behavior. Replacement, dismissal, expiry or quit cancels preview work and destroys the panel. Selection hides existing panels through the capture visibility mechanism. A pending preview must not newly appear while the thumbnail is suspended.
- An active mask follows the existing renderer. Automatic masking continues to send still captures to the editor before any thumbnail can exist. Preserve light/dark appearance and the existing quick actions.

## Testing decisions

- Extend the existing native `quick-actions` scenario with the real Preview control, expanded raster and bounds, close without discarding, light/dark rendering, and capture suspension and cancellation. Assert visible state and no change to the foreground app. Exercise late work and lifetime with the existing synthetic renderer and clock where the target control flow scores above 5 in `cccc`.
- Check two synthetic documents differing only under an identical secure mask through the existing RED test seam. Verify at the renderer boundary and at the native panel where practical.
- Run the unsigned gate and bilingual native replay on the exact commit. Physical VoiceOver, mixed-display, and Spaces checks need a dedicated desktop.

## Out of scope

The next tickets cover optimized save and Copy Text. This slice adds no new preferences, media directories, upload paths, Quick Look file system cache, or operating system permission.
