# Reference inventory — 2026-10-14

## Evidence boundary

Read-only installed-bundle inspection: Shottr 1.9.3/build 137 (`cc.ffitch.shottr`, macOS 12+),
CleanShot X Setapp 5.0.1/build 5.0.1 (`com.getcleanshot.app-setapp`, macOS 13+).
Neither competitor was launched; personal screen content, credentials and private preferences
were not read. Resources were enumerated, not copied. Recortia baseline: 0.11.0/build 18.

Official current sources: [Shottr](https://shottr.cc/),
[CleanShot screenshots](https://cleanshot.com/screenshots),
[CleanShot features](https://cleanshot.com/features),
[CleanShot changelog](https://cleanshot.com/changelog).
An existing capability below is code/contract evidence, not a newly passed physical acceptance
test. The full repository gate must recheck it; manual qualification remains in BACKLOG.json.

## Behavior coverage and gaps

| Capability | Reference | Recortia entry / implementation | Existing acceptance | Tour page / decision |
|---|---|---|---|---|
| Region, display, chosen window | Both | Menu capture commands / CaptureCoordinator | CAP-01/02, GEO | Capture / existing |
| Timer, repeat region, cursor/shadow options | Both | Menu and Settings › Capture | CAP-01 | Capture / existing |
| PNG/JPEG import, paste/drop | Both | Menu / ImportCoordinator | IO-01 | Capture / existing |
| Vertical manual/automatic scroll | Both | Scrolling Capture / ScrollSessionModel | SCR-01…04, PERM | Capture / existing, physical compatibility pending |
| Text, straight arrows, shapes, freehand, highlight, steps | Both | Editor / AnnotationRenderer | EDIT-01/02 | Editing / existing |
| Crop, resize, zoom/pan, selection, ordering, undo; Shift constraints | Both | Editor / EditorModel; Shift keeps aspect/squares and snaps arrows to 45°; layers retain aspect | EDIT, GEO, EditorCompositionTests | Editing / existing |
| Secure opaque masks; cosmetic blur/pixelate | Both | Editor / RenderPrivacyRenderer | RED-01…03 | Editing / preserve stronger source-pixel contract |
| Local text recognition, QR | Both | Capture Text / editor recognition / Vision | OCR-01/02 | Recognition / existing, EN/PT-BR qualification |
| Pixel loupe, ruler, HEX/RGB sRGB | Shottr | Editor pixel tools / PixelSampler | PIX-01, GEO | Recognition / existing |
| Multiple image layers, opacity, side-by-side | Both | Editor composition / EditorModel+Composition | COMP-01, RED | Composition / existing |
| Background, padding, corners, shadow, spotlight, magnifier | Both | Editor presentation / RenderEffects | COMP-01, RED | Composition / existing |
| Pins, opacity/zoom, sanitized Copy/Drag | Both | Editor pin / PinsModel and PinPanels | PIN-01, window-presence | Composition / existing, normal-level policy |
| PNG clipboard, PNG/JPEG atomic Save, Drag Out | Both | Editor / ExportCoordinator and ShareSnapshot | EXP, RED | Sharing / existing |
| Automatic copy/save and opt-in upload | Both | Settings / AppModel and GitHubUploader | NET-01, automatic-export | Sharing / GitHub only, before later edits |
| Shortcuts and native settings | Both | Menu / shortcut recorder and SettingsWindowController | UX-01, PERM | Shortcuts / existing |
| Curved arrows | Both | Optional quadratic control, shared painted geometry, native Curved/Straight and Bend X/Y | 683-test development gate, stable CI and independent code/security + bilingual native acceptance pass | Development acceptance; physical input/release excluded; see curved-arrows/acceptance-verdict.md |
| Additional arrowhead styles | Both | Existing filled head retained | No implementation gate yet | Gap: not implemented; curves do not establish all four CleanShot styles |
| Straight line tool without arrowheads | CleanShot | Distinct endpoint-based line annotation, shared renderer, native toolbar/shortcut D | EDIT/GEO/RED focused regressions and bilingual annotations E2E pass | Source implemented; final acceptance pending |
| Saved annotation colors | CleanShot | Bounded sealed palette and native inspector controls | EDIT-01 / palette regressions | Bilingual native controls pass; final independent acceptance pending |
| Predefined text appearances | CleanShot | Seven typed font/outline/box appearances; native input and boxed-only background controls | EDIT/EXP/RED; independent code/security and source-blind native development acceptance recorded in text-appearance/decoration-acceptance-verdict.md | Development accepted; physical/minimum-OS/release qualification pending. Separate CAP-01 integration FAIL remains open. User-named saved presets are separate. |
| Hand-drawn annotation style | Shottr | Explicitly deferred in SPEC | Not implemented | Gap: not implemented |
| Smart capture selection/snapping, frozen capture selection and capture aspect constraints | Both | No equivalent verified in capture; editor constraints already exist | CAP/GEO extension needed | Gap: not implemented in capture |
| Average-area color | Shottr | Color-picker inspector 1×1/3×3/5×5, encoded sRGB mean of the current sanitized preview; @concurrent bounded tile | PIX-01 extension and bilingual integrated E2E pass | Recognition / source verified; physical qualification pending |
| Text color, OKLCH, APCA contrast | Shottr | No equivalent verified | PIX extension needed | Gap: not implemented; APCA must not be mislabeled WCAG AA |
| Horizontal scroll | CleanShot | Vertical-only contract | New SCR/GEO corpus needed | Gap: not implemented |
| Stroke smoothing / smart highlighter | CleanShot | Current freehand renderer | EDIT/RED corpus needed | Gap: not implemented |
| Rotate/flip | CleanShot | No user transform command | GEO/COMP/RED needed | Gap: not implemented |
| WebP/HEIC, multipage print | CleanShot | PNG/JPEG-only contract | IO/EXP/RED needed | Gap: not implemented; codec availability must be verified |
| Reusable presentation presets/image backgrounds | CleanShot | No equivalent verified | COMP/RED needed | Gap: not implemented |
| Auto Balance and presentation aspect/alignment controls | CleanShot | Uniform padding only; no content-aware balancing or preset output aspect | COMP/GEO/RED needed | Gap: not implemented |
| Quick-action thumbnail | Both | Real editor presented after capture | editor-presentation/CAP | Gap: not implemented; preserve real presentation contract |
| Always-on-top/click-through pins | Both | Normal-level switchable pins per ADR-007 | PIN/window-presence/Space | Conflicts with approved pin behavior; recovery design required |
| Editable persistent projects | CleanShot | In-memory documents, flattened public exports | PRIV/RED/IO threat model | Protected persistence decision, not implemented |
| Searchable screenshot history | CleanShot | No screenshot archive | PRIV | Prohibited automatic archive under current contract |
| URL schemes / integrations | Both | FR-16 deferred | New automation consent tests | Protected integration design, not implemented |
| S3 sharing | Shottr | FR-15 GitHub provider only | New NET provider suite | Protected provider/credentials design, not implemented |
| Cloud collaboration/comments/teams/protected links | CleanShot | No backend/accounts | New storage/network/security design | Protected architecture, not implemented |
| Video/GIF, audio, camera, keystrokes, Studio Mode | CleanShot | Screenshot-only product | New privacy/resource/permission design | Recording/audio/keylogging conflict; not implemented |
| Telemetry / startup network | Shottr | Default offline | PRIV-01 | Explicitly excluded |

## What can and cannot be learned from the installed resources

- Shottr Assets.car enumerates 224 entries, including introductory art and pixel/text/average
  color helpers; the bundle includes native interface resources.
- CleanShot Assets.car enumerates 1,333 entries, including menu-bar/shortcut introduction,
  OCR/scroll guides and Studio Mode media. Bundled cwebp/gifsicle and frameworks establish
  their presence only, not runtime use, telemetry, algorithm quality or optimization.
- No proprietary algorithms, cache design, stitching heuristics, source code or benchmark
  methodology were established. Marketing timings are not Recortia measurements.
- Recortia's existing bounded inputs, off-UI imaging, sanitized render graph and explicit
  capture sessions are its own implementation decisions; preserve and measure them.

## Qualification and completion

This inventory does not establish full competitor parity. Every gap remains visibly unfinished
until an end-to-end implementation and its tests exist. Protected product changes require a
concrete reviewed safety decision; verification of proprietary internals is unavailable without
authoritative published evidence. Do not convert either limitation into a PASS.
