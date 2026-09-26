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

Supports the documented distinction between Shottr Cloud and a user-supplied S3 destination. Framepin does not reuse either service and defers its own optional sharing integration.

## S04 — Shottr URL scheme documentation

URL: `https://shottr.cc/kb/urlschemes`

Supports the existence of external workflow integration as a reference capability. Framepin does not adopt the proprietary scheme name or presume that externally invoked side effects are safe.

## S05 — Apple Xcode SDK and system requirements

URL: `https://developer.apple.com/xcode/system-requirements`

Apple's current table lists Xcode 27 with Swift 6.4, Swift 6 language mode, and a macOS 26.6-or-later build host. The table also distinguishes beta versions. The exact installed Xcode/SDK build is not known from this research and must be recorded locally. Support claims concern Apple's table, not a tested Framepin build.

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

Supports the candidate dependency's user-customizable global shortcut interface and its statement that it does not produce permission dialogs. The inspected README labels version 3.1.0. M0 must resolve and review an actual stable revision instead of assuming that this README value is a verified immutable release lock.

## S10 — Bishop Fox: Unredacter

URL: `https://github.com/BishopFox/unredacter`

Primary research implementation demonstrating why pixelation is unsuitable as a secure-redaction guarantee. Framepin does not need to import this code or its dependencies. Its own opaque-mask and export tests are independently specified.

## S11 — Apple: Signing your apps for Gatekeeper

URL: `https://developer.apple.com/developer-id/`

Readable official guidance on Developer ID, Hardened Runtime, notarization, and notarytool/stapler. This informs a proposed distribution gate; it is not evidence that the current documentation bundle contains a signed application.

## S12 — Sparkle documentation

URL: `https://sparkle-project.org/documentation/`

Supports using the project's supported update integration and EdDSA signing procedure. Resolve the current stable version and applicable configuration in the release milestone. Do not invent a signature, feed URL, public key, or recovery result.

## S13 — GitHub Actions: Secure use reference

URL: `https://docs.github.com/en/actions/reference/security/secure-use`

Primary guidance for CI trust separation and dependency/workflow security. The proposed Framepin release process is not an existing workflow and must be validated independently.

## S14 — Open Source Initiative: MIT license

URL: `https://opensource.org/license/mit`

Supports identifying MIT as an open-source license option. Final ownership, third-party compatibility, notices, and any needed legal review remain maintainer responsibilities. This specification does not grant rights to Shottr's assets or to Apple's proprietary frameworks.

## External assertions not made

No claim is made about a cleared product name/domain, a published repository, complete Shottr internal behavior, benchmark equivalence, App Store eligibility, unlimited S3-provider compatibility, future SDK/model availability, real OCR accuracy, byte-reproducible signed artifacts, or passing hardware/security tests.
