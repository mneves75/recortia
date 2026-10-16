# Capability inventory — 2026-10-14

## Evidence boundary

This inventory lists capabilities that macOS screenshot utilities commonly offer, taken from
public product documentation and read-only inspection of installed app bundles, and records
Recortia's status for each. No third-party app was launched, nothing was copied, and no
proprietary code or algorithm was inferred. Recortia baseline when written: 0.11.0/build 18.

An existing capability below is code/contract evidence, not a newly passed physical acceptance
test. The full repository gate must recheck it; manual qualification remains in BACKLOG.json.

## Behavior coverage and gaps

| Capability | Recortia entry / implementation | Existing acceptance | Tour page / decision |
|---|---|---|---|
| Region, display, chosen window | Menu capture commands / CaptureCoordinator | CAP-01/02, GEO | Capture / existing |
| Timer, repeat region, cursor/shadow options | Menu and Settings › Capture | CAP-01 | Capture / existing |
| PNG/JPEG import, paste/drop | Menu / ImportCoordinator | IO-01 | Capture / existing |
| Vertical manual/automatic scroll | Scrolling Capture / ScrollSessionModel | SCR-01…04, PERM | Capture / existing, physical compatibility pending |
| Text, straight arrows, shapes, freehand, highlight, steps | Editor / AnnotationRenderer | EDIT-01/02 | Editing / existing |
| Crop, resize, zoom/pan, selection, ordering, undo; Shift constraints | Editor / EditorModel; Shift keeps aspect/squares and snaps arrows to 45°; layers retain aspect | EDIT, GEO, EditorCompositionTests | Editing / existing |
| Secure opaque masks; cosmetic blur/pixelate | Editor / RenderPrivacyRenderer | RED-01…03 | Editing / preserve stronger source-pixel contract |
| Local text recognition, QR | Capture Text / editor recognition / Vision | OCR-01/02 | Recognition / existing, EN/PT-BR qualification |
| Pixel loupe, ruler, HEX/RGB sRGB | Editor pixel tools / PixelSampler | PIX-01, GEO | Recognition / existing |
| Multiple image layers, opacity, side-by-side | Editor composition / EditorModel+Composition | COMP-01, RED | Composition / existing |
| Background, padding, corners, shadow, spotlight, magnifier | Editor presentation / RenderEffects | COMP-01, RED | Composition / existing |
| Pins, opacity/zoom, sanitized Copy/Drag | Editor pin / PinsModel and PinPanels | PIN-01, window-presence | Composition / existing, normal-level policy |
| PNG clipboard, PNG/JPEG atomic Save, Drag Out | Editor / ExportCoordinator and ShareSnapshot | EXP, RED | Sharing / existing |
| Automatic copy/save and opt-in upload | Settings / AppModel and GitHubUploader | NET-01, automatic-export | Sharing / GitHub only, before later edits |
| Shortcuts and native settings | Menu / shortcut recorder and SettingsWindowController | UX-01, PERM | Shortcuts / existing |
| Curved arrows | Optional quadratic control, shared painted geometry, native Curved/Straight and Bend X/Y | 683-test development gate, stable CI and independent code/security + bilingual native acceptance pass | Development acceptance; physical input/release excluded; see curved-arrows/acceptance-verdict.md |
| Additional arrowhead styles | Existing filled head retained | No implementation gate yet | Gap: not implemented; curves do not establish other arrowhead styles |
| Straight line tool without arrowheads | Distinct endpoint-based line annotation, shared renderer, native toolbar/shortcut D | EDIT/GEO/RED focused regressions and bilingual annotations E2E pass | Source implemented; final acceptance pending |
| Saved annotation colors | Bounded sealed palette and native inspector controls | EDIT-01 / palette regressions | Bilingual native controls pass; final independent acceptance pending |
| Predefined text appearances | Seven typed font/outline/box appearances; native input and boxed-only background controls | EDIT/EXP/RED; independent code/security and source-blind native development acceptance recorded in text-appearance/decoration-acceptance-verdict.md | Development accepted; physical/minimum-OS/release qualification pending. Separate CAP-01 integration FAIL remains open. User-named saved presets are separate. |
| Hand-drawn annotation style | Explicitly deferred in SPEC | Not implemented | Gap: not implemented |
| Smart capture selection/snapping, frozen capture selection and capture aspect constraints | No equivalent verified in capture; editor constraints already exist | CAP/GEO extension needed | Gap: not implemented in capture |
| Average-area color | Color-picker inspector 1×1/3×3/5×5, encoded sRGB mean of the current sanitized preview; @concurrent bounded tile | PIX-01 extension and bilingual integrated E2E pass | Recognition / source verified; physical qualification pending |
| Text color, OKLCH, APCA contrast | No equivalent verified | PIX extension needed | Gap: not implemented; APCA must not be mislabeled WCAG AA |
| Horizontal scroll | Vertical-only contract | New SCR/GEO corpus needed | Gap: not implemented |
| Stroke smoothing / smart highlighter | Current freehand renderer | EDIT/RED corpus needed | Gap: not implemented |
| Rotate/flip | No user transform command | GEO/COMP/RED needed | Gap: not implemented |
| WebP/HEIC, multipage print | PNG/JPEG-only contract | IO/EXP/RED needed | Gap: not implemented; codec availability must be verified |
| Reusable presentation presets/image backgrounds | No equivalent verified | COMP/RED needed | Gap: not implemented |
| Auto Balance and presentation aspect/alignment controls | Uniform padding only; no content-aware balancing or preset output aspect | COMP/GEO/RED needed | Gap: not implemented |
| Quick-action thumbnail | Real editor presented after capture | editor-presentation/CAP | Gap: not implemented; preserve real presentation contract |
| Always-on-top/click-through pins | Normal-level switchable pins per ADR-007 | PIN/window-presence/Space | Conflicts with approved pin behavior; recovery design required |
| Editable persistent projects | In-memory documents, flattened public exports | PRIV/RED/IO threat model | Protected persistence decision, not implemented |
| Searchable screenshot history | No screenshot archive | PRIV | Prohibited automatic archive under current contract |
| URL schemes / integrations | FR-16 deferred | New automation consent tests | Protected integration design, not implemented |
| S3 sharing | FR-15 GitHub provider only | New NET provider suite | Protected provider/credentials design, not implemented |
| Cloud collaboration/comments/teams/protected links | No backend/accounts | New storage/network/security design | Protected architecture, not implemented |
| Video/GIF, audio, camera, keystrokes, Studio Mode | Screenshot-only product | New privacy/resource/permission design | Recording/audio/keylogging conflict; not implemented |
| Telemetry / startup network | Default offline | PRIV-01 | Explicitly excluded |

## Qualification and completion

This inventory does not establish parity with any other product. Every gap remains visibly
unfinished until an end-to-end implementation and its tests exist. Recortia's bounded inputs,
off-UI imaging, sanitized render graph and explicit capture sessions are its own implementation
decisions; preserve and measure them. Protected product changes require a concrete reviewed
safety decision. Marketing timings are not Recortia measurements. Do not convert either
limitation into a PASS.
