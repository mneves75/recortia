# Modernisation audit for the macOS 26 floor

Source: Opus 5.5 (medium), read-only, 2026-11-19, at b2726b4. Every SDK claim was checked by
searching the `.swiftinterface` files, headers or the PackageDescription interface in Xcode 27.2's
MacOSX27.2.sdk. Nothing was built or run. The coordinator's verdicts are in `../review-list.md`.

Summary: very little code exists because of the macOS 15 floor. Raising it to 26 is mostly a
three-line change plus deliberate choices, not a large deletion.

## Ranked findings

`path:line | today | 2026 replacement | lines ± | risk | verified how`

1. `project.yml:6,11`, `Packages/RecortiaKit/Package.swift:12` | 15.0 / `.macOS(.v15)` | `"26.0"`
   and `.macOS(.v26)` (tools 6.2 has it; `.v16` is unavailable, renamed `v26`), then
   `xcodegen generate` | ±3 | low; `LSMinimumSystemVersion` follows the setting | PackageDescription
   interface, `v26` at line 572.
2. `RecortiaApp/Editor/EditorRootView.swift:128-131` (comment at :89) | `ToolbarItem { Spacer(minLength: 8) }`
   keeps Copy out of the history group's capsule | `ToolbarSpacer(.fixed, placement: .primaryAction)`
   | −3 | low; rerun `editor-toolbar` at 980 pt because `visibleItems` changes | SwiftUI interface
   :29649, macOS 26.0.
3. `Packages/RecortiaKit/Sources/Imaging/RenderRaster.swift:80,97,116,129`,
   `DecodeContainerHeaders.swift:305` | `withUnsafe(Mutable)Bytes`, invariants only in comments; the
   raw-buffer subscript is bounds-checked only in Debug; :80 is the solid-mask `fill` | `Data`'s
   `mutableSpan` / `span` | about −5 | medium: the mask pixel path, needs the RED family and a timing
   check | Foundation interface :5732/:5772. Not a floor item (back-deploys to 10.14.4).
   `withContext` (:49) stays unsafe because `CGContext(data:)` needs a pointer.
4. `Packages/RecortiaKit/Package.swift:34` | no `swiftSettings`, while the app has
   `SWIFT_APPROACHABLE_CONCURRENCY: YES` (`project.yml:15`), so the same `nonisolated async` code
   means different things in the two places | `.enableUpcomingFeature("NonisolatedNonsendingByDefault")`
   and `"InferIsolatedConformances"` | +4 to 6 | medium: plain `async` functions in
   Imaging/MacPlatform would run on the caller's actor; every heavy one must already be
   `@concurrent` (about 14 are) | manifest and `project.yml` read.
5. Same manifest, Imaging and MacPlatform | none | `.strictMemorySafety()` | +2 plus about 10
   `unsafe` markers on what remains after item 3 (`CGContext(data:)`, `Darwin.write` at
   `FileSink.swift:208`, `acl_free` at :164/:233/:334/:344, `ImageInput.swift:16`, CryptoKit
   `withUnsafeBytes` at `KeychainPreferenceIntegrity.swift:70,74,113`) | low | PackageDescription :67.
6. `RecortiaApp/App/ObservationLoop.swift:1-24` ("macOS 15 has no `Observations`") | hand-rolled
   `withObservationTracking` re-armed through `Task` | an `Observations { … }` loop in each of the 5
   callers (`PinPanels.swift:18`, `EditorCanvasView.swift:39`, `CaptureUIController.swift:33`,
   `CaptureWindowVisibility.swift:28`, `ScrollUIController.swift:28`) | about −4 net | medium:
   `Observations` is transactional and its first value arrives asynchronously, so the synchronous
   render at init and intermediate states can be lost. Keep `AppModel.swift:213` (`decideQuit`),
   whose generation-counter contract is in AGENTS.md | Observation interface :142, anyAppleOS 26.0.
7. B-2 App Intents (new code) | see below | +150 to 250 | medium.
8. `RecortiaApp/Pins/PinPanels.swift:161,234`, `Capture/HostingPanel.swift`, `App/DragChip.swift:53`
   | opaque `windowBackgroundColor`, standard titled panels | `.glassEffect` / `GlassEffectContainer`
   / `NSGlassEffectView` | +10 to 30 | high: glass samples what is behind it, so `ChromeAppearance`
   and `appearance-contrast` stop being deterministic. Building against SDK 27 already gives the
   system glass toolbar and sidebar on 26+. Needs a design decision.
9. `MacPlatform/LiveScreenCaptureBackend.swift:56-66` | `SCStreamConfiguration` + `captureImage` |
   `SCScreenshotConfiguration` + `captureScreenshot(contentFilter:configuration:)` (macOS 26) | ±0 |
   medium: adds only HDR; no `captureResolution`; its `fileURL` writes raw pixels to disk, which
   breaks the ShareSnapshot invariant and must never be used. Keep the current code.
10. SwiftUI, small: `EditorInspectorView.swift:467-468,696-697` `.onAppear(perform: load)` + `.onChange`
    → `.onChange(of:initial: true)` (−2). Keep the 19 `Binding(get:set:)` in the inspector (they route
    through undoable commands) and the chooser focus via `onAppear` (gated AGENTS.md invariant). No
    `AnyView`, `GeometryReader` or `ObservableObject`.
11. Concurrency is clean: no `Task.detached`, `@unchecked Sendable` or `nonisolated(unsafe)`. The SCStream
    sample-handler `DispatchQueue` is required. The `addObserver(queue: .main) { MainActor.assumeIsolated }`
    sites cannot move to typed notification messages: `NSWindow.DidBecomeKeyMessage` and
    `NSApplication.DidBecomeActiveMessage` are macOS 27.0 in the SDK.
12. Enhanced Security (what changes, not a proposal): condition 3 in
    `docs/specs/release-review-0.12.5/xcode-security-settings.md` ("deployment target macOS 15.0, no
    macOS 15 host") becomes "test on macOS 26 and the current release"; this host runs 27.3, so a
    macOS 26 host is still missing. Conditions 1 and 2 (`arm64e`, exact entitlements) stand. Gaps in
    that document: the local package will not build `arm64e` without `macOSPackagesShouldBuildARM64e`
    in the workspace settings, and `SWIFT_STRICT_MEMORY_SAFETY` is missing from its "not applicable"
    row. Memory tagging needs M5 or later; checked pointer arithmetic is iOS/watchOS only.

## Vision detected data (decides the auto-redaction design)

Vision 26 reports e-mail addresses and phone numbers as typed values with locations.
`RecognizeDocumentsRequest` (macOS 26.0) returns `[DocumentObservation]`;
`observation.document.text` (also `.title`, `.paragraphs`) is `Container.Text` with
`detectedData: [DocumentObservation.Container.DataDetectorMatch]`. Each match has
`boundingRegion: NormalizedRegion` and `match: DataDetection.DataDetector.Match` (DataDetection is
macOS 26.0) with `range: Range<String.Index>?` and `details: SemanticDetails`: `.emailAddress`,
`.phoneNumber`, `.link`, `.postalAddress`, `.calendarEvent`, `.moneyAmount`, `.flightNumber`,
`.shipmentTrackingNumber`, `.measurement`, `.paymentIdentifier`. `Container.barcodes` returns the same
`BarcodeObservation`, so `QRBitstream.swift` stays.

## App Intents pattern for B-2

- One `AppIntent` per action, each calling `AppModel.perform(_:)` (`AppModel.swift:162`) on the main
  actor; `.captureRegion`, `.captureWindow` and `.captureText` show the same overlay or chooser as the
  menu (the on-screen step).
- `supportedModes = .background`, no `openAppWhenRun`: `.foreground(.immediate)` activates the app and
  conflicts with the non-activating overlay and the Space invariants.
- Open Image and Pin Image take `@Parameter IntentFile` with image content types and go through
  `ImageImporter.admit` before reading bytes; prefer `fileURL` over `data` so admission bounds size.
- Return `.result()` with no image: returning pixels to Shortcuts would be an export that bypasses
  ShareSnapshot.
- An `AppShortcutsProvider` with EN and pt-BR phrases; type names and phrases are a public contract.
- `AppIntentsTesting`, `LongRunningIntent` and `IntentExecutionTargets` are macOS 27: not usable at a
  26 floor without gating.

## Open questions

1. Should Capture Text return the recognized text to Shortcuts? That moves text to another process.
2. Should A-6 use `detectedData`? The plan says the UI never claims anything was "detected".
3. Glass HUDs, given the appearance gate in item 8?
4. Is a macOS 26 host available for testing the new minimum OS?
