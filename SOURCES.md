# Research sources and verification boundaries

**Checked:** September 26, 2026. These sources support external facts in the specification. Requirement IDs, product limits, milestones, architecture, and performance gates are original proposed decisions, not statements that Shottr or Apple uses that implementation.

No Shottr binary or Mac hardware was tested. Some Apple symbol-documentation pages exposed a JavaScript-only view; where that prevented inspection, readable official WWDC transcripts and Apple's support table were used instead. Exact symbol availability and build settings still require M0 verification in the selected installed SDK.

## S01 — Shottr product page and release notes

URL: `https://shottr.cc/`

Supports the listed 1.9.2 release on September 17, 2026 and the high-level workflow inventory. The site contains vendor performance claims; those are not independent measurements and are not adopted as this project's achieved results.

## S02 — Shottr FAQ

URL: `https://shottr.cc/kb/faq`

Supports the existence of manual scrolling fallback and acknowledged compatibility limitations. This was important when rejecting an unqualified “works with every app” requirement.

## S03 — Shottr upload documentation

URL: `https://shottr.cc/kb/upload/`

Supports the documented distinction between Shottr Cloud and a user-supplied S3 destination. Recortia does not reuse either service and defers its own optional sharing integration.

## S04 — Shottr URL scheme documentation

URL: `https://shottr.cc/kb/urlschemes`

Supports the existence of external workflow integration as a reference capability. Recortia does not adopt the proprietary scheme name or presume that externally invoked side effects are safe.

## S05 — Apple Xcode SDK and system requirements

URL: `https://developer.apple.com/xcode/system-requirements`

Apple's current table lists Xcode 27 with Swift 6.4, Swift 6 language mode, and a macOS 26.6-or-later build host. The table also distinguishes beta versions. The exact installed Xcode/SDK build is not known from this research and must be recorded locally. Support claims concern Apple's table, not a tested Recortia build.

## S06 — Apple: What's new in ScreenCaptureKit, WWDC23

URL: `https://developer.apple.com/videos/play/wwdc2023/10136/`

Readable official explanation of ScreenCaptureKit screenshot capture, SCScreenshotManager, content filtering/configuration, and the distinction between still capture and streaming. This is a stable foundational API source, not a claim that a 2023 session describes every 2026 addition.

## S07 — Apple: Discover Swift enhancements in the Vision framework, WWDC24

URL: `https://developer.apple.com/videos/play/wwdc2024/10163/`

Readable official discussion of Vision's Swift/concurrency-oriented API. Individual request/language capabilities must be checked against the selected SDK and at runtime; the spec does not infer every supported language from this session.

## S08 — Swift.org: Swift 6.2 Released

URL: `https://www.swift.org/blog/swift-6.2-released/`

Supports the concurrency caveat about caller isolation, the explicit @concurrent option, and testing evidence features. It is intentionally used for language semantics introduced earlier, not as the latest Swift version. The selected 2026 toolchain is based on S05.

## S09 — KeyboardShortcuts upstream repository

URL: `https://github.com/sindresorhus/KeyboardShortcuts`

Supports the dependency's user-customizable global shortcut interface and its statement that it
does not produce permission dialogs. Package.resolved pins 3.1.0 at
`772133d9dbe800fdac0473226822994c5c162c58`. On 2026-09-29,
scripts/test-release-contract.py verified the checkout revision and the bundled MIT notices
against the source and actual unsigned app bundles.

## S10 — Bishop Fox: Unredacter

URL: `https://github.com/BishopFox/unredacter`

Primary research implementation demonstrating why pixelation is unsuitable as a secure-redaction guarantee. Recortia does not need to import this code or its dependencies. Its own opaque-mask and export tests are independently specified.

## S11 — Apple: Signing your apps for Gatekeeper

URL: `https://developer.apple.com/developer-id/`

Readable official guidance on Developer ID, Hardened Runtime, notarization, and notarytool/stapler. This informs a proposed distribution gate; it is not evidence that the current documentation bundle contains a signed application.

## S12 — Sparkle documentation

URL: `https://sparkle-project.org/documentation/`

Supports using the project's supported update integration and EdDSA signing procedure. Resolve the current stable version and applicable configuration in the release milestone. Do not invent a signature, feed URL, public key, or recovery result.

## S13 — GitHub Actions: Secure use reference

URL: `https://docs.github.com/en/actions/reference/security/secure-use`

Primary guidance for CI trust separation and dependency/workflow security. The proposed Recortia release process is not an existing workflow and must be validated independently.

## S14 — Open Source Initiative: MIT license

URL: `https://opensource.org/license/mit`

Supports identifying MIT as an open-source license option. Final ownership, third-party compatibility, notices, and any needed legal review remain maintainer responsibilities. This specification does not grant rights to Shottr's assets or to Apple's proprietary frameworks.

## S15 — Apple: NSPasteboard.clearContents()

URL: `https://developer.apple.com/documentation/appkit/nspasteboard/clearcontents()`

Consulted on 2026-09-29 using Apple's Markdown documentation. Clearing the pasteboard removes
its previous contents before a later write; failure copy must not promise preservation once
that step has occurred. Encoding failures still occur before the sink clears anything.

## S16 — Swift Evolution: Structured concurrency (SE-0304)

URL: `https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md`

The proposal by John McCall, Joe Groff, Doug Gregor and Konrad Malawski explains cooperative
cancellation. Consulted on 2026-09-29: cancellation does not replace request/session identity
checks when asynchronous work resumes. The scrolling regression suspends an old step and verifies
that it cannot block or clear ownership belonging to a replacement session.

## S17 — Apple: NSWindow ordering

URLs: `https://developer.apple.com/documentation/appkit/nswindow/orderout(_:)`,
`https://developer.apple.com/documentation/appkit/nswindow/orderback(_:)`

Consulted through Xcode-beta MCP DocumentationSearch on 2026-09-29. `orderOut` preserves the
window's resources but separately ordering out a child detaches it from its parent. `orderBack`
restores visibility without changing the key/main window. Recortia hides top-level windows and
lets AppKit preserve their child relationships; the recapture E2E checks that relationship.

## S18 — Screenshot workflows from product maintainers

URLs: `https://shottr.cc/kb/customareacapture`, `https://shottr.cc/kb/faq`,
`https://cleanshot.com/features`

Reviewed on 2026-09-29. These workflows informed the comparison of hiding, minimizing, closing,
transparent windows, and app-wide hiding. Temporary top-level window ordering preserves the
existing editing session with the smallest behavioral change. No parity or benchmark claim
follows from documentation research.

## S19 — Review and user-control guidance

URLs: `https://martinfowler.com/articles/preparatory-refactoring-example.html`,
`https://www.nngroup.com/articles/user-control-and-freedom/`

Reviewed on 2026-09-29: small test-backed corrections and reversible workflows informed the
implementation. This is published guidance, not a personal consultation with either author.

## External assertions not made

No claim is made about a cleared product name/domain, a published repository, complete Shottr internal behavior, benchmark equivalence, App Store eligibility, unlimited S3-provider compatibility, future SDK/model availability, real OCR accuracy, byte-reproducible signed artifacts, or passing hardware/security tests.
