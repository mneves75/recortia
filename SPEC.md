# Recortia — Agent-Ready Software Specification

**Document version:** 1.0  
**Research date:** 2026-09-26  
**Status:** Approved FR-01…FR-14 implementation contract; beta implementation and automated tests exist.
Manual qualification and the in-app updater remain pending; see README.md and BACKLOG.json.
**Product name:** Recortia is the approved public name (ADR-003). The recorded name search is not legal trademark clearance.
**Intent:** Independently implement an open-source, native macOS alternative to Shottr. “AI agent” means the coding agent building the product; an LLM is not required inside the application.

## 1. Scope and evidence

This document separates externally verified facts from proposed engineering decisions. Source identifiers resolve in `SOURCES.md`. MUST denotes a release-blocking requirement; SHOULD permits a documented, reviewed exception; MAY denotes optional scope. All performance figures below are proposed targets, not measured results.

Shottr's website currently lists version 1.9.2, released September 17, 2026, with macOS 27 compatibility improvements. Its documented capabilities include capture, annotation, scrolling capture, OCR/QR, pinning, measurement, color inspection, image composition, presentation backgrounds, and sharing. Its knowledge base acknowledges scrolling incompatibilities and a manual fallback. These are the reference workflows, not a promise that every feature can be reproduced identically. [S01, S02, S03, S04]

Only public behavior and documentation were inspected. No binary was executed, disassembled, or inspected. Do not reproduce proprietary code, branding, assets, license checks, or website copy. Build an independent interface and implementation. Use synthetic or appropriately licensed test assets.

**Product promise:** Capture, clarify, redact, and share a screenshot quickly, locally, and predictably. The main workflow is one invocation, one selection, optional editing, and one explicit export action.

## 2. Decisions for the first implementation

| Area | Decision | Reason / boundary |
|---|---|---|
| Platform | Native macOS, Apple Silicon only for v1 | Focus effort on Mac integration and measurable responsiveness. Intel and other operating systems are not promised. |
| Deployment target | macOS 15.0+ | Deliberate compatibility baseline, independent of the build SDK. Test on 15, 26, and 27 before declaring support. |
| Toolchain | Stable Xcode 27, its Swift 6.4 compiler, Swift 6 language mode | Apple's current support table lists this combination. Freeze the exact locally verified build in M0; exclude beta toolchains from releases. [S05] |
| Build host | A Mac satisfying Xcode's host requirements | Apple currently lists macOS 26.6 or later for Xcode 27. A deployment target of 15 does not mean Xcode 27 can run on 15. [S05] |
| UI | SwiftUI for settings and chrome; AppKit for capture overlays, editor canvas, panels, focus, and window lifecycle | Choose the simplest appropriate native API for each surface. |
| Capture | ScreenCaptureKit; one-shot screenshot API for stills; SCStream only during an explicit scrolling session | Apple's documented screenshot interface avoids requiring a continuously running capture stream. [S06] |
| OCR / QR | Vision, preferably its modern Swift request interfaces available at the baseline | Verify individual symbols against the installed SDK; no bundled OCR runtime or paid API. [S07] |
| Rendering | Core Graphics, Core Image where appropriate, Accelerate for measured image-processing hotspots | No custom Metal renderer until profiling establishes a need. |
| State | Explicit document model, command-based undo, typed state machines, structured concurrency | Avoid implicit state scattered across views and callbacks. |
| Storage | UserDefaults for preferences; screenshots and OCR in memory by default | No database, account, screenshot archive, or background indexing in v1. |
| Distribution | One directly distributed, Developer ID-signed, notarized app with Hardened Runtime | The proposed build is **not App Sandbox-restricted**, to accommodate optional cross-app scrolling control without a separate helper architecture. This is an explicit security tradeoff, not an assertion that sandboxing and Hardened Runtime are equivalent. [S11] |
| Permissions | Screen Recording just in time; Accessibility only for separately enabled automatic scrolling | Basic capture, editing, imported-image OCR, export, and manual scrolling must not require Accessibility or Input Monitoring. |
| Dependencies | Native frameworks first; KeyboardShortcuts as the initial approved third-party candidate; Sparkle in the release milestone | Resolve reviewed stable versions and commit Package.resolved; do not invent dependency hashes. [S09, S12] |
| License | MIT license for original project code, recorded in LICENSE | Preserve third-party notices. MIT is an OSI-listed license. [S14] |
| Network | No app-initiated network requests on a fresh installation | Update checks require opt-in or a manual action. Upload and cloud AI are absent from the v1 core. |

No backend, webview shell, Electron, Tauri, React, authentication server, telemetry SDK, plugin runtime, or LLM orchestration framework is needed for this scope. These are product choices, not claims that those technologies are generally unsuitable.

## 3. Release scope and parity boundaries

A release may only advertise features with passing acceptance evidence. A 0.1 release is a useful subset, not full Shottr parity. A 1.0 release is a local-first alternative with explicit limitations, not a claim of universal scrolling support.

| ID | Capability | Release | Verification family |
|---|---|---|---|
| FR-01 | Menu-bar operation, onboarding, global shortcuts with macOS-style defaults (ADR-005) | 0.1 | UX / PERM |
| FR-02 | Region, display, selectable-window, delayed, and repeat-region capture | 0.1 | CAP / GEO |
| FR-03 | Open PNG/JPEG, paste an image, and drop an image into the editor | 0.1 | IO / PRIV |
| FR-04 | Crop, zoom, pan, resize; select, move, delete, duplicate; undo/redo | 0.1 | EDIT / GEO |
| FR-05 | Text, arrow, rectangle, ellipse, freehand, highlighter, numbered steps | 0.1 | EDIT |
| FR-06 | Solid secure redaction; cosmetic blur/pixelation clearly distinguished | 0.1 | RED |
| FR-07 | Flattened PNG/JPEG save, PNG clipboard copy, safe drag-out | 0.1 | EXP / RED |
| FR-08 | On-device OCR and QR decoding, EN and PT-BR workflows | 0.1 | OCR |
| FR-09 | Floating reference pins with opacity, zoom, and explicit close | 0.1 | PIN / PRIV |
| FR-10 | Manual and automatic vertical scrolling capture with confidence checks | 1.0 | SCR / PERM |
| FR-11 | Pixel loupe, ruler, dimensions, sRGB color inspection | 1.0 | PIX / GEO |
| FR-12 | Multiple-image canvas, transparency overlays, side-by-side comparison | 1.0 | COMP / RED |
| FR-13 | Background, padding, corner radius, shadow, spotlight, magnifier callout | 1.0 | COMP / RED |
| FR-14 | Native settings, accessibility, EN/PT-BR localization, release/update flow | Foundation in 0.1; complete in 1.0 | UX / REL |
| FR-15 | Optional upload to user-controlled S3-compatible storage | Post-1.0, separate approval | NET |
| FR-16 | Approved local automation and optional on-device writing assistance | Post-1.0, separate approval | AUTO / AI |

Deferred rather than silently omitted: horizontal scrolling; cross-display selections; arbitrary nested-scroll reliability; text-only object removal/inpainting; intelligent object snapping; hand-drawn styling; contrast analyzers; before/after animation; editable project files; persistent history/search; CLI/App Intents/URL integrations; HDR-preserving export; Intel/Windows/Linux support; cloud hosting.

The 1.0 automatic-scroll target is Safari, Chrome, and a native scroll-view fixture on supported macOS releases. Other applications get manual mode and a compatibility report, not an “any app” guarantee. Terminal, virtualized lists, canvas-based editors, and scroll-modifying utilities belong in the explicit unsupported/limited matrix until tested. Shottr itself documents comparable classes of limitations. [S02]

## 4. Users and primary workflows

The primary users are developers reporting bugs, designers checking pixels, and people preparing concise visual explanations. There is one local user role; no account, organization, or administrator role exists in the app.

1. **Capture and explain:** Invoke an assigned shortcut, select a region, add an arrow and label, and copy a rendered PNG.
2. **Protect and share:** Capture or import an image, mark confidential regions, inspect the flattened preview, and save or drag only the sanitized export.
3. **Read inaccessible text:** Invoke OCR, select an area, review recognized text, and copy it. Imported-image OCR works without screen permission.
4. **Keep a reference:** Pin a rendered screenshot, adjust opacity or zoom, and explicitly close it. Pins do not silently intercept clicks intended for other apps.
5. **Capture a long page:** Select a supported viewport, scroll manually or explicitly enable automatic control, inspect seams, and accept a complete or clearly labeled partial result.
6. **Inspect or compose:** Measure image geometry, sample a color, compare two images, add presentation framing, and export at a declared scale.

## 5. Functional contracts

### FR-01 — App shell and shortcuts

**Story:** As a Mac user, I want a keyboard-first utility that stays out of my way.

The app MUST expose capture commands, Open Image, Settings, About, and Quit from its menu-bar menu. First launch MUST explain local processing and let the user assign shortcuts. Default shortcuts mirror the macOS Screenshot app (⇧⌘3 display, ⇧⌘4 region with Space for a window, ⇧⌘5 capture menu; ADR-005): Recortia never turns Apple's screenshot shortcuts off, holds a default while macOS still uses it, and says how to free it. A shortcut recorder MUST report detected system/menu conflicts and registration failures without claiming exhaustive knowledge of all other apps. KeyboardShortcuts documents user-configurable registration without permission prompts. [S09]

Launch at login is off until selected. The editor follows the active Space and capture display when possible, without repeatedly stealing focus. App reactivation MUST reuse the existing process. Settings MUST remain reachable when all image windows are closed. Capture cancellation MUST never imply copy, save, or upload.

### FR-02 — Capture

**Input:** CaptureRequest with unique ID, mode, optional delay, requested display/window, cursor/shadow preferences, and target geometry.  
**Output:** CapturedFrame with immutable pixel content and a CaptureGeometry record, or a typed error.

Provide region, individual display, user-selected window, a configurable 0–10 second delay, and repeat-last-region. Repeat geometry is session-only and bound to the source display identity/configuration, not an unchecked global rectangle. If the display disappears, rotates, or materially changes configuration, invalidate it and ask for a new selection.

Region selection MUST work on every connected display, including negative desktop origins. A single region cannot cross displays in v1; clamp visibly to the starting display and explain the limitation. Do not silently resample a multi-display region. A window shortcut must use a reliable source identifier; when the foreground app has multiple ambiguous windows, present a chooser instead of guessing.

Use public ScreenCaptureKit APIs, exclude the app's overlay/editor/pin windows by default, and hide the cursor unless explicitly requested. Verify exclusions with a visible checkerboard test overlay. Do not use private capture frameworks, shell `screencapture`, or `CGWindowListCreateImage` as the primary implementation. One-shot capture and stream capture are separate code paths. [S06]

Before a new capture selection, temporarily hide existing visible Recortia windows without closing
their documents. Keep them hidden through countdown and collection, then restore their previous
visibility without taking focus. Replacement selections must not restore them early, and windows
closed during capture must not reopen. Still capture and scrolling share one active-session limit.

Capture MUST stop on cancellation, permission loss, screen lock, target disappearance, or a relevant display reconfiguration. Respect protected content; do not attempt a bypass. A dark image alone is not reliable proof of capture denial: use reported errors and target state, and avoid mislabeling legitimately black content.

### FR-03 — Import and clipboard input

Decode local PNG/JPEG only in v1. Verify format, dimensions, frame count, orientation, row-stride arithmetic, and allocation budget before full decode. Limit compressed inputs to 64 MiB and decoded image area to 40 megapixels. Reject unsupported multi-frame content rather than silently choosing a frame. Oversized images get a clear error; optional downsampling may be offered before decoding only if it is demonstrably bounded.

Import MUST NOT overwrite its source by default. Clipboard reads occur only on explicit Paste/Open from Clipboard; there is no clipboard polling. Do not fetch remote image URLs or execute embedded content. Orientation MUST be normalized exactly once.

### FR-04 / FR-05 — Editor and annotation

An editor document stores immutable raster assets plus editable annotation commands. Geometry belongs to document/source coordinates, never view zoom coordinates. Crop and resize remain reversible during the session. Undo/redo stores commands and compact state, not a complete bitmap for every pointer movement. Group one drag/drawing gesture into one undo step; budget undo memory, evict oldest complete groups visibly, and preserve a clean saved-state marker.

Tools MUST support consistent selection handles, hit testing, move, resize, duplicate, delete, stroke/fill/opacity, z-order, and keyboard nudging. Text editing MUST handle multiline input, Unicode, accents, emoji, bidirectional text, and input-method composition without dispatching editor shortcuts into text input. Numbered steps remain editable and have an explicit renumber command.

Provide fit, actual-pixel, zoom-in/out, selection zoom, and Space-drag pan. Basic arrows precede curved arrows; decoration is not a dependency of correct capture or export. No drawn object may change position merely because the editor zoom changed.

### FR-06 — Redaction

**The promise is about pixels in the new exported artifact, not about deleting every earlier copy or detecting every secret.** Blur and pixelation are cosmetic obfuscation, not secure redaction. Pixelation can retain recoverable text information. [S10]

The default privacy tool MUST replace selected source pixels with a fully opaque solid color. Masks MUST cover pixel boundaries conservatively, be applied before resampling or neighborhood effects, and invalidate dependent render/OCR/magnifier caches. When the same image asset is used in multiple places, source-bound masks must apply to all render references to that asset. Independently reimported copies and secrets elsewhere are not automatically discovered; make this limitation clear.

Adding a mask to a composite maps intersected raster-layer regions into each asset's coordinate system and also maintains an output-space mask for vector/text coverage. If a transform cannot be safely mapped, reject the operation or require an explicit flatten-and-redact workflow; never fall back to a translucent overlay.

Secure export MUST create a fresh, flattened raster with no original layer, undo record, alternate unredacted representation, textual OCR metadata, hidden thumbnail, or transparent RGB leak. Ordinary project/document models must never go directly to an export sink. OCR and magnifiers operate on the privacy-sanitized view of the document. A project-file format is deliberately outside v1.

Do not promise that OCR-based “find sensitive data” is exhaustive. Do not promise secure erasure of memory, SSD blocks, backups, other apps' clipboard histories, or files the user exported earlier.

### FR-07 — Export and explicit side effects

All save, clipboard, drag-out, and later upload operations MUST receive the same immutable ShareSnapshot produced by the approved export pipeline. The snapshot identifies document revision, privacy epoch, output format/scale/color space, and sanitized bytes. It contains no raw source references.

PNG is the default. JPEG requires flattening transparency against an explicit background and a declared quality setting. Copy Image publishes only the sanitized PNG representation in v1; no simultaneous raw TIFF, original file URL, or app-private document payload. Encode successfully before replacing clipboard content, and report success only after the clipboard write succeeds.

Save uses a user-selected destination or a previously authorized preferred folder, sanitized collision-resistant filenames, a same-directory temporary file, and atomic replacement/rename where supported. Overwrite requires confirmation. Encode failure leaves the destination intact. Quota, revocation, full disk, and disconnected volumes are explicit errors. File promises for drag-out must keep sanitized bytes alive until the receiving app completes or the transfer is canceled; do not delete a promised file prematurely.

Auto-copy and auto-save are off by default. If later enabled, show that copying/saving happens before subsequent edits and cannot be retracted from other applications. An ordinary screenshot filename MUST NOT include a window title, recognized text, account identifier, or URL.

### FR-08 — OCR and QR

Run Vision locally and off the UI actor. Support a crop-to-text command and OCR on imported images. Prefer the modern Swift API where verified; Apple documents its concurrency-oriented redesign. [S07]

Query available recognition languages at runtime. Offer English and Portuguese where supported; report unavailable language support instead of asserting that a particular locale is always present. Provide exact/raw text, optional whitespace normalization, and preserve-line-breaks modes. Never silently autocorrect source text or use an LLM to “repair” OCR in the default workflow.

Recognized ranges MUST have normalized bounding boxes converted through the shared geometry layer. OCR is tied to document revision and privacy epoch; outdated results cannot overwrite the clipboard after a new capture or redaction. Text mode with no detected text leaves existing clipboard content unchanged and displays a nonblocking message.

Decode QR payloads as untrusted data. Display the payload; copy or open only after an explicit user action. Never automatically follow URLs, Wi-Fi configuration, payment payloads, or executable/deep-link schemes. QR fixture equality is byte-level, not visual approximation.

### FR-09 — Pins

Pin a rendered document snapshot, not an invisible live recording. Provide move, scale, opacity, close, and “bring pins forward” controls. Maximum five pins initially, subject to the common memory budget. Do not create a click-through pin unless an explicit mode also provides an always-reachable recovery action; default pins are normal interactive panels.

Pins referencing a live document MUST be refreshed or invalidated on privacy-epoch changes. Closing the source editor and keeping a pin requires retaining only the data necessary for that rendered reference. Pins disappear on app quit and are not restored from disk. Always-on-top behavior must respect system security surfaces and does not promise display above every full-screen/system window.

### FR-10 — Scrolling capture

Manual scrolling is the mandatory first implementation and fallback. Automatic scrolling is opt-in, asks for Accessibility only when selected, and directs minimal scroll actions at the chosen target. No typing, clicking unrelated controls, clipboard reading, AppleScript automation, Input Monitoring, or global key-event recording is allowed.

The session MUST show its source, capture status, stop control, and progress. A user-assigned Stop/Toggle shortcut works while another app is focused; Escape cancels when Recortia owns focus. Do not install a broad keyboard hook just to observe Escape everywhere.

Pipeline: capture stable viewport frames; normalize orientation/scale; mask known fixed bands; estimate coarse vertical displacement; refine matches in multiple independent overlap regions; require displacement consensus and calibrated confidence; choose a seam without blending text; append only newly exposed content; update preview. Use fixtures and profiling to choose the implementation; do not invent a universal magic confidence threshold.

Handle stationary frames, smooth scrolling, repeated text, lazy-loaded assets, fixed headers/footers, animated cursors, and a page ending. Low texture or repetitive patterns may be inherently ambiguous: pause, offer manual overlap adjustment, retain a clearly labeled partial result, or stop. Do not stretch missing content or fabricate pixels with generative AI.

Choose an initial vertical direction. Unexpected reversal pauses rather than duplicating content. Limit duration to 120 seconds, input to 200 accepted frames, output to 40 megapixels, any side to 32,768 pixels, and default output height to 20,000 pixels; the first reached limit wins. Output limits include final encoding buffers, not just matching thumbnails.

Keep at most two full-resolution viewport buffers plus bounded working tiles and previews. Do not assume ImageIO can encode an arbitrarily large output without materializing it. Refuse operations that exceed the declared allocation plan. A user-confirmed partial result may be exported, but must never be labeled complete. Stop immediately on target/focus/display change, lock, permission revocation, or canceled control. Focus may move between the bound target and Recortia's own UI; another app taking focus ends the session.

### FR-11 — Pixel tools

Provide a nearest-neighbor loupe and distinguish document pixels from logical display points and editor zoom. An imported image without screen geometry has pixels but no inferred screen-point scale. Report width, height, positions, and manually anchored horizontal/vertical distances. Any automatic edge detection is an estimate that can be adjusted.

Canonical v1 editing/export is SDR sRGB. The picker reports sampled values in that space as HEX and RGB; it is not a measurement of physical display light. Label the space explicitly and keep rulers independent of zoom. HDR preservation, wide-gamut numeric formats, and contrast standards are deferred until separately specified and tested.

### FR-12 / FR-13 — Composition and presentation

Add imported images as independently movable/scalable layers on an expandable canvas, with alignment, opacity, duplication, and remove. Never silently stretch aspect ratio. Include a simple side-by-side layout preset and a transparency comparison view.

Add background fill/gradient, padding, corner radius, and shadow as parameters. The canvas itself stays color-neutral and unaffected by translucent window materials. Provide spotlight and magnifier callouts only after source-redaction propagation and cache invalidation tests pass. Magnifier sources cannot point to the final composited output and create a render cycle. All tools use the same export geometry as the preview.

### FR-14 — Settings, accessibility, and release behavior

Use native controls, system typography, and platform-adaptive chrome. Availability-gate newer presentation APIs rather than raising the deployment target merely for appearance. Respect Reduce Motion, Reduce Transparency, increased contrast, light/dark mode, and keyboard focus visibility. Tool state cannot be communicated by color alone.

Provide VoiceOver labels, an accessible annotation list, keyboard-adjustable geometry, textual status/error messages, and keyboard alternatives to essential actions. A custom drawing canvas is not automatically accessible; it needs deliberate accessibility elements and hardware/user testing.

Externalize all UI strings in a String Catalog from the first milestone; ship English and PT-BR in v1. Do not translate document content or filenames implicitly. Settings cover shortcuts, capture/export, privacy, pins, OCR, scrolling, and opt-in updates. No setting should imply permissions have been granted when the operating system denies them.

## 6. Architecture and repository layout

Use one app plus one local Swift package with three meaningful targets. Avoid a generic plugin bus, global service locator, event-sourced backend, or dozens of micro-packages.

```text
Recortia.xcodeproj                 # proposed app project and shared schemes
RecortiaApp/
  App/                            # composition root, lifecycle, menu bar
  CaptureUI/                      # selection overlays and capture HUD
  EditorUI/                       # AppKit canvas, SwiftUI toolbar/inspector
  Pins/
  Settings/
  Resources/                      # original assets and String Catalog
Packages/RecortiaKit/
  Package.swift
  Sources/Domain/                 # values, geometry, commands, states, policies
  Sources/Imaging/                # render, masks, OCR, matching, bounded decode
  Sources/MacPlatform/            # SCK, permissions, shortcuts, clipboard, files
  Tests/DomainTests/
  Tests/ImagingTests/
  Tests/MacPlatformTests/
RecortiaUITests/
Fixtures/                         # synthetic/licensed inputs + expected outputs
Configuration/                    # xcconfig, actual toolchain record
scripts/                          # build/check entrypoints created in M0/M1
.github/workflows/
docs/adr/
```

Dependency direction: Domain has no AppKit/SwiftUI/ScreenCaptureKit dependency; Imaging depends on Domain; MacPlatform depends on Domain and narrowly on Imaging; the app composes them. A feature may be a folder before it warrants a module. Package and target names above are proposed, not existing repository facts.

The composition root injects CaptureService, PermissionService, RenderService, OCRService, ExportService, ClipboardService, FileAccessService, Clock, and IDGenerator through small interfaces. Only external or nondeterministic boundaries need protocols. Native concrete types are fine internally.

### Concurrency policy

UI/window/clipboard operations belong to MainActor where required. UI state uses explicit `@MainActor` isolation and Observation. Domain values are immutable and Sendable where appropriate. Rendering, matching, OCR, and image decoding run in explicitly isolated worker actors or audited concurrent functions, with bounded task counts and cancellation.

An `async` function is not automatically a background task: Swift's concurrency model can keep async work on its caller's actor. Audit actual build settings; use explicit isolation or `@concurrent` where supported and appropriate. [S08] Do not silence compiler diagnostics with wholesale `@unchecked Sendable`, blanket `@preconcurrency`, `nonisolated(unsafe)`, or detached tasks. Audit each Core Foundation/framework object at the boundary against the selected SDK's annotations.

Every result carries request ID, document revision, and privacy epoch. On completion, the UI accepts it only if all still match and the request was not canceled. A late OCR/render/capture callback cannot reopen a closed editor, replace a newer result, or write the clipboard.

### State machines

Capture: `idle -> permissionCheck -> selecting/countdown -> capturing -> editing`, with explicit `canceled` and `failed` terminals returning to idle. At most one active capture session; a second invocation cancels/replaces according to one documented policy, never starts an unbounded queue.

Scroll: `idle -> selecting -> armed -> collecting <-> paused -> reviewing -> accepted`, plus `canceled` and `failed`. A partial result must have a partial status and reason.

Export: `requested -> snapshotting -> sanitizing -> rendering -> encoding -> committing -> succeeded`; failure/cancellation before commit has no success notification. Cancellation after a file/clipboard commit must report that the action already completed rather than pretending it was undone.

## 7. Data model and geometry contract

| Entity | Required fields / invariant |
|---|---|
| CaptureRequest | ID, mode, target token, delay, requested geometry, cursor/shadow flags |
| CaptureGeometry | source display/window identifier, bounds, orientation, actual pixel size, point-to-pixel transform, capture timestamp |
| ImageAsset | ID, immutable decoded handle, pixel dimensions, canonical color space, alpha convention; never inferred from DPI metadata alone |
| Document | ID, revision, asset references, layer transforms, annotations, crop, export scale, backdrop, privacy epoch, dirty state |
| Annotation | ID, typed tool payload, geometry, style, z-order; no arbitrary script or serialized executable object |
| SecureMask | ID, asset ID and source-pixel mask, output-space coverage where needed, opaque fill, privacy epoch |
| OCRResult | request ID, revision, privacy epoch, text blocks, confidence, boxes, language metadata |
| ScrollSession | target token, stable geometry, direction, accepted offsets, confidence, limits, completion reason |
| ShareSnapshot | revision/epoch, output dimensions, format, canonical metadata, immutable encoded sanitized bytes |
| Preferences | schema version, hotkeys, explicit toggles, preferred folder authorization; no screenshots or OCR text |

Define distinct geometry types for desktop points, display-local points, source pixels, document coordinates, and editor-view coordinates. One conversion module owns axis direction, rotation, scaling, crop offsets, and rounding. Never apply a hard-coded 2x scale or a single main-screen scale to every monitor.

Round crop/mask boundaries outward and clamp safely. Reject NaN, infinity, negative dimensions, overflow, and off-image spans. Orientation normalization happens once; every subsequent transform is explicit and invertible where required. Point/pixel conversion must use actual image dimensions and capture geometry, not a PNG's nominal DPI tag.

## 8. Privacy-preserving render and export pipeline

```text
Immutable document revision + privacy epoch
    -> validate geometry, resource budget, and render graph
    -> apply source-bound opaque masks to all source-asset references
    -> crop / transform / resample sanitized sources
    -> compose image layers and privacy-safe dependent effects
    -> draw annotations and presentation background
    -> enforce output-space masks for vector/edge coverage
    -> normalize alpha and allowlisted metadata
    -> encode new PNG or JPEG
    -> immutable ShareSnapshot
    -> explicit clipboard / file / drag-out / approved future upload
```

Sanitize **before** filters that sample neighbors, magnification, resampling, and later AI processing. Reapply output coverage conservatively after transformations. Changes to masks invalidate every affected cache. A preview-only opaque rectangle is not an acceptable implementation.

Export metadata is an allowlist, initially dimensions, encoding requirements, and an appropriate sRGB profile/marker. Strip imported EXIF/XMP/IPTC, comments, textual chunks, location, original filenames, thumbnails, and OCR payloads. Keep color interpretation necessary for correct viewing; “strip everything” must not accidentally remove essential color information.

External sinks cannot request an original asset from the image store. A static dependency check and contract tests should make accidental raw-asset export difficult. No secure export path may include custom document pasteboard types or hidden image representations.

## 9. Security and privacy boundaries

The app deliberately writes no screenshot/OCR content before an explicit save or drag-export action. Session data is volatile, with bounded caches and no restoration archive. Operating-system swap, diagnostic collection, or third-party clipboard managers are outside that guarantee. User-facing privacy language must preserve this distinction.

Log durations, dimensions, error categories, cancellation, and bounded counters; never pixels, OCR text, QR payloads, document/window titles, clipboard content, paths, access tokens, or user identifiers. Do not include real captures in crash reports or issue templates. Diagnostic export is explicit, previewable, content-free by default, and reviewed before public submission.

Use just-in-time permissions. No TCC database modifications, blanket permission-reset scripts, admin helpers, private entitlements, disabling SIP/Gatekeeper, or instructions to grant Full Disk Access. Screen permission denial must not disable import/edit/local export. Automatic scrolling has a separate denial/fallback path.

The proposed non-sandboxed distribution increases the consequences of compromised app code. Document that decision in ADR-002, keep the dependency surface small, prohibit arbitrary execution and network plugins, and review an App Sandbox configuration before release. Do not claim that application-level file policies are an OS-enforced sandbox.

All screenshot text, QR contents, filenames, imported metadata, issue comments, and future AI outputs are untrusted. Never turn them into shell commands, executable configuration, tool authority, or automatic network destinations.

## 10. Resource and performance targets

Benchmark on a physical Apple Silicon Mac with at least 16 GB RAM, a 4K 60 Hz display, Release build, stable OS/toolchain, warmed app, and pre-granted permissions. Record actual hardware and OS patch. Exclude human selection time and permission dialogs from capture latency. Report p50/p95, sample count, cold/warm distinction, and measurement endpoints.

| Measure | Proposed gate | Measurement |
|---|---|---|
| Warm capture overlay presentation | p95 <= 100 ms | Shortcut handler entry to first overlay frame, 100 runs |
| Region commit to editor image | p95 <= 300 ms for a 4K-or-smaller still | Selection commit to first full-resolution editor frame, 100 runs |
| Cold launch to ready menu bar | p95 <= 1.5 s | 30 process launches; report caching conditions |
| Common drawing gestures | 60 Hz target without sustained main-thread stalls | Frame pacing plus Instruments traces, not FPS claims alone |
| Local OCR | p95 <= 1.5 s on the defined 1080p text fixture subset | 100 runs; report languages, revision, and corpus |
| Idle process footprint | <= 80 MiB target with no documents/pins open | Median physical footprint over five minutes |
| Idle CPU | <= 0.5% of one core | Average over five minutes; no capture, timer polling, or OCR work |
| Heavy workflow footprint | <= 512 MiB target for the declared 40 MP limit | Include decode, matching, export, and framework allocations |
| Leaks | No retained sessions/windows/frame buffers after 200 capture-close cycles | Memory graph and steady-state plateau; account for allocator caches |

Hard input/output limits protect correctness independently of these performance targets. If measured framework allocations prevent meeting a budget, reduce supported limits or obtain a reviewed target change; do not suppress the benchmark. Do not claim Shottr's advertised timings as the project's measured performance.

## 11. Test strategy and definition of done

Use Swift Testing for deterministic unit and parameterized tests, XCTest/XCUITest for UI and relevant performance integration, image fixtures for pixel-level regression, and a physical-Mac manual suite for permissions, displays, Spaces, HDR input behavior, and signed distribution. Swift's testing support can attach concrete evidence such as images and logs. [S08]

A mock permission provider tests state handling, not the real TCC prompt. Hosted CI without a suitable GUI/display cannot prove capture behavior. Screenshots of the editor do not prove exported pixels are correct. Human review does not replace a deterministic redaction test.

Every feature MUST have a requirement ID, test IDs, documented error/cancellation behavior, and evidence of its assigned gates. `ACCEPTANCE_TESTS.md` defines the shared scenarios; `IMPLEMENTATION_PLAN.md` assigns owners/dependencies. A hidden unfinished UI is preferable to a fake implemented control, but an advertised feature with a stub is a release blocker.

## 12. Open-source and release requirements

Publish complete original source, build instructions, dependency lockfile, license/third-party notices, CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, changelog, and decision records. The application can use Apple's system frameworks while its own code is open source; that does not make Apple's OS/toolchain/model assets open source.

PR builds run with read-only repository permissions, no signing/update secrets, and immutable reviewed action references. Never execute untrusted fork code in a privileged release workflow or on a maintainer's personal Mac. GitHub explicitly documents least privilege, immutable action pinning, and the hazards of privileged untrusted checkouts. [S13]

Release builds MUST derive from a reviewed tag and record source commit, exact toolchain, dependency versions, test evidence, license inventory/SBOM, and artifact hashes. Signing/notarization credentials exist only in a protected release environment with human approval. Build, sign with Hardened Runtime, notarize using supported tooling, staple, and test the downloaded artifact on a clean user account. Apple documents Developer ID and notarytool/stapler for this distribution path. [S11]

Use Sparkle's supported signing flow rather than inventing an updater; require valid update signatures, compatible deployment targets, a clear changelog, and tamper/failure tests. Automatic update checks are opt-in. Sparkle documents EdDSA archive signing and key-rotation constraints. [S12]

Document reproducible build **inputs**; do not claim byte-for-byte reproducible notarized/signature-bearing artifacts without demonstrating that stronger property. Free source builds and signed public distribution have different credential and infrastructure requirements. Never advise users to disable Gatekeeper as the normal installation path.

## 13. Post-1.0 contracts, not current implementation authorization

### Optional S3-compatible sharing

Add only after a separately approved threat model and provider design. Upload an already reviewed ShareSnapshot, never raw assets. Use user-owned destination configuration, Keychain for credentials, explicit destination/visibility confirmation, transport security, least-privilege bucket/prefix access, cancellation, and tested retry semantics. Preserve one object key per approved upload intent so retries do not create accidental duplicates.

Do not grant public ACLs automatically or present an unguessable URL as authentication. Private presigned access should be the default where a provider supports it. Display link expiry and explain that local deletion, remote object deletion, and revocation of cached links are different actions. Never forward credentials across redirects; provider compatibility must be tested, not inferred from the phrase “S3-compatible.” No uploader-owned backend is required.

### Optional local automation and on-device AI

An integration may open the app or initiate a user-visible workflow; an untrusted deep link must not silently capture, save, upload, or overwrite the clipboard. Strictly allowlist actions/parameters and require confirmation at the side-effect boundary. Do not ship an arbitrary scripting or tool-execution engine.

Optional writing assistance may suggest alt text, summarize user-selected OCR text, or draft a bug report locally. Availability, supported languages, and model access are runtime capabilities. It must remain off the capture critical path, work without any cloud fallback, and show editable output before a side effect. Recheck the then-current SDK/model documentation before selecting an implementation. Do not assume an earlier year's model/API capability set is still current.

Screenshot content is data, not instructions. AI has no authority to capture additional screens, access files, invoke tools, apply “secure redaction,” or transmit data. Automatic sensitive-data suggestions remain review aids, not a guarantee that no secrets remain.

## 14. Completion and first handoff

The project is complete for a named release only when all assigned requirements, acceptance tests, resource budgets, physical-device checks, privacy gates, and release checks pass or have a maintainer-approved scope reduction reflected in user-facing documentation.

The initial documentation-only handoff required approval before implementation. The owner has
since approved FR-01…FR-14 (AGENTS.md); BACKLOG.json records implemented work and outstanding
qualification. Continue one coherent approved task at a time with exact verification evidence,
without repeated confirmation for actions already authorized. This specification grants no
authority for FR-15/FR-16, live personal-screen access, credential access, publishing, or other
external side effects; those require separate authorization.
