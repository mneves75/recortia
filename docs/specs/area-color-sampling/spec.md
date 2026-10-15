# Bounded area color sampling

## Assumptions

- The parent-approved brief replaces the feature interview for this ticket.
- Sampling uses the editor's current sanitized base image, in image pixels, independent of zoom.
- Existing single-pixel behavior remains the default. The loupe and hover inspection remain single-pixel.
- The choices are 1×1, 3×3 and 5×5; no arbitrary-radius control, persistence or new dependency is needed.

## Contract

FR-11 / PIX-01 gains an explicit sample-size choice in the color-picker inspector. An intentional
click samples a square centered on the addressed pixel, clipped to the image bounds. The sample
averages encoded 8-bit sRGB premultiplied channels and alpha, then unpremultiplies once. RGB uses
the unrounded channel/alpha sums; final RGB and alpha round to the nearest integer, halves up.
When the resulting alpha is zero, RGB is also zero. This is an encoded sRGB average, not a linear
light, perceptual contrast or text/background classification feature.

Sampling accepts radii 0, 1 and 2 only, validates coordinates and radius before allocation, and
allocates at most a 5×5 raster. Invalid coordinates or unsupported radii return no sample. The
editor retains its `isBaseCurrent` gate and never samples a raw asset. A sample-size change clears
the previous picked result and requires a new click. Redaction invalidation clears both inspection
and the picked result; a stale base cannot produce or copy an old color.

## Public seams and failure modes

- `PixelSampler.color` and `PixelSampler.averageColor`: exact known colors, clipped corners/edges, alpha weighting, transparent
  hidden RGB, invalid coordinates, extreme radii, and single-pixel compatibility.
- `EditorModel.pickColor`, sample-size selection and explicit copy: only deliberate picks use
  the selected average; inspection/loupe stay nearest-pixel; stale/redacted results cannot leak.
- Native inspector: labeled keyboard-accessible picker; English and Brazilian Portuguese text.

`averageColor` is `@concurrent` and runs its single bounded raster on the generic executor. The
editor keeps the existing synchronous 1×1 path and uses cancellable area-pick requests. Completion
must match the full document request identity, current base key and image identity, selected sample
size, and newest request token. Every document edit invalidates picked results and pending requests.

The focused unit suites use literal synthetic RGBA fixtures. The parent's full gate and synthetic
EN/PT-BR editor E2E validate integration separately. No live screen content, TCC or physical display
qualification is authorized by this ticket.
