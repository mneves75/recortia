# Xcode security settings — audit and decision record

Source of the audit: `~/dev/Skills/audit-xcode-security-settings` (Dimillian's Skills), read
2026-10-28. This file is the decision document that skill asks for; no build setting or entitlement
was changed by this pass, and every row says why.

Current state of the project (`project.yml`, `RecortiaApp/Recortia-Release.entitlements`):

| Setting / capability | Now | Verdict |
|---|---|---|
| `ENABLE_HARDENED_RUNTIME` | `YES` | Already hardened; nothing to do |
| `SWIFT_STRICT_CONCURRENCY` | `complete` | Already the strictest value; the gate compiles clean under Swift 6 mode |
| `SWIFT_TREAT_WARNINGS_AS_ERRORS` / `GCC_TREAT_WARNINGS_AS_ERRORS` | `NO` | Left as recorded. Turning them on is a separate decision with a real cost: a vendor SDK warning would block every gate, and the toolchain here is a release candidate |
| `ARCHS` | `arm64` | Deliberate: `SPEC.md` §2 ships arm64 only. Pointer authentication would add an `arm64e` slice, which is a product decision, not a build tweak |
| Reviewed entitlements | `application-identifier`, `team-identifier`, `keychain-access-groups` | `scripts/check-release-entitlements.py` requires this **exact** set, so any new entitlement is a deliberate, reviewed change with its own gate update |
| Clang static analyzer, `GCC_WARN_SHADOW`, `CLANG_WARN_EMPTY_BODY`, `ENABLE_SECURITY_COMPILER_WARNINGS`, C++ hardening, typed allocators, checked pointer arithmetic | — | **Not applicable.** The skill's own reference says: "Only enable or inquire about a setting if the codebase contains code in a language the setting applies to… Do not enable clang-only settings for pure Swift codebases." This repository is pure Swift: no C, C++, or Objective-C sources, and the only AppKit imports in Imaging are the two reviewed `NSFont` classes |

## Enhanced Security — deferred, with the conditions an adoption must meet

`ENABLE_ENHANCED_SECURITY = YES` is supported for `com.apple.product-type.application` on macOS, so
it is technically in scope. It is not adopted here, because it is not a build flag: it changes the
shipped binary and its entitlements at once, and this host cannot validate the result.

What it would change:

1. **Binary architecture.** It cascades `ENABLE_POINTER_AUTHENTICATION`, which appends `arm64e` to
   `ARCHS_STANDARD`. `project.yml` pins `ARCHS: arm64` and the release pipeline hashes that bundle.
2. **Entitlements.** It requires `com.apple.security.hardened-process` plus the
   `enhanced-security-version-string`, `hardened-heap`, `dyld-ro` and `platform-restrictions-string`
   keys. `scripts/check-release-entitlements.py` accepts an exact reviewed set, so the gate must be
   updated in the same change, deliberately.
3. **Runtime OS.** The deployment target is macOS 15.0. The v2 protections are an OS capability, so
   the app has to be exercised on macOS 15 and on the newest release before the entitlement ships;
   no macOS 15 host exists for this project, and `SPEC.md` §10 already records that release evidence
   from a release-candidate toolchain does not qualify.

Order an adoption should follow (from the skill's own adoption strategy): security compiler warnings
and stack zero-init first (compile-time only), then read-only platform memory, then runtime
restrictions and typed allocators, then the annotated code hardening. Phases 1–2 require no source
changes for well-behaved code; this app has no raw Mach IPC, no custom allocator, and no XPC service,
so the expected cost is low but unproven.

Done when: a build with the capability enabled passes `scripts/check.sh`, the bilingual E2E on a
stable-OS host at 50/50, `scripts/check-release-binary.sh`, and a notarized candidate launched on
macOS 15 and on the current release; and `scripts/check-release-entitlements.py` has been updated to
the new exact set with its own test.

## Other skills in the collection, and what each produced here

| Skill | Applies | Result |
|---|---|---|
| `modernize-tests` | No | No source file imports XCTest; the package suites already use Swift Testing |
| `swiftui-view-refactor` | Finding only | `EditorInspectorView.swift` (1030 lines) and `EditorCanvasView.swift` (925) are the two files that would pay off; splitting them is a refactor with its own spec, not a review fix |
| `swiftui-performance-audit`, `swift-concurrency-expert` | Already covered | The architecture review of 2026-10-28 produced the three open performance findings (text-layout memoisation, AX messaging timeout, retained-pixel budget); the target builds clean under Swift 6 strict concurrency |
| `macos-menubar-tuist-app` | No | This app uses XcodeGen, not Tuist |
| `macos-spm-app-packaging` | No | It ships an Xcode project and `scripts/release.sh` |
| `ios-debugger-agent`, `device-interaction` | No | macOS app with its own DEBUG E2E harness; no simulator workflow |
| `app-intents-specialist`, `app-intents-whats-new-27` | No | No App Intents surface; Shortcuts support is out of v1 scope in `SPEC.md` |
| `app-store-changelog` | No | Not distributed on the App Store; `CHANGELOG.md` is maintained per release |
| `review-swarm`, `bug-hunt-swarm`, `review-and-simplify-changes`, `orchestrate-batch-refactor`, `project-skill-audit` | Process skills | Their equivalent ran this session: three read-only reviewers, an adversarial review of the diff, a spec-conformance pass and the repository gate |
| `xctrace`, `swiftui-liquid-glass`, `swiftui-whats-new-27`, `app-resizability`, `building-document-based-swiftui-applications`, `react-component-performance`, `github` | Deferred or not applicable | Profiling needs a stable-OS host; the Liquid Glass and What's New skills target the iOS 26 API set, while this app already uses the macOS equivalents it needs |
