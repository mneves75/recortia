# Feature discovery and reference parity

## Assumptions (owner requested no interview)

- Preserve the native macOS 15+ product, its existing Space/window policy, consent model,
  and ShareSnapshot export boundary. No proprietary code or assets are copied.
- Explain every currently implemented capability, including limitations and opt-in exports;
  do not advertise reference-app capabilities that Recortia does not implement.
- Use the existing OnboardingModel/SettingsStore public seam and the bilingual synthetic
  native E2E runner. No live personal-screen capture, credential reads or real uploads.
- Stable Xcode remains the delivery gate; installed Xcode 27.2 beta is supplementary.
- The owner authorized a working branch, commits, push, merge, a beta tag and local macOS
  installation. Public release/notarization services are separate from local installation.
- Preserve preexisting untracked docs/handoffs and preexisting build/scratch directories.
- Specs/tickets are tracked locally under docs/specs, as required by the current owner
  contract; existing GitHub bug triage remains unchanged.

## Problem Statement

The first-run flow covers only privacy and shortcuts. People cannot discover the implemented
capture, editor, recognition, scrolling, inspection, composition and sharing workflows, or
reopen the introduction after completing it. A blanket reference-parity claim would also hide
the distinction between implemented capabilities, unqualified hardware behavior and excluded
recording/cloud features.

## Solution

A skippable native feature tour at first launch, available again from the menu bar. Short,
task-oriented pages explain what to do, what happens locally, and which exports or permissions
require a deliberate choice. A source-backed reference inventory and sequenced implementation
plan distinguish existing behavior, missing behavior, and unresolved product boundaries.

## User Stories

1. As a new user, I want a brief introduction so I can start without reading a manual.
2. As a new user, I want to skip from any page so education never blocks my work.
3. As a user, I want to go back so I can revisit an explanation.
4. As a user, I want visible progress so I know how much remains.
5. As a user, I want to reopen the tour without resetting my preferences.
6. As a user, I want to understand region/display/window/delayed/repeat capture.
7. As a user, I want to import, paste or drop an image without screen permissions.
8. As a user, I want manual and automatic scrolling explained with their failure limits.
9. As a user, I want to discover annotations, crop, resize, zoom/pan and undo/redo.
10. As a user, I want secure redaction distinguished from cosmetic blur/pixelation.
11. As a user, I want to discover local OCR and safe QR handling.
12. As a user, I want to discover pixel inspection, ruler and sRGB color copy.
13. As a user, I want to discover pins, multiple images and presentation effects.
14. As a user, I want to understand sanitized Copy/Save/drag and PNG/JPEG choices.
15. As a user, I want opt-in automatic exports and GitHub sharing explained accurately.
16. As a user, I want shortcut conflicts explained without changing macOS settings for me.
17. As a Portuguese-speaking user, I want complete pt-BR content.
18. As a keyboard or assistive-technology user, I want native labeled controls and scrollable content.
19. As a returning user, I want normal/login launch behavior preserved.
20. As the maintainer, I want reference claims and qualification gaps traceable to evidence.

## Implementation Decisions

- Extend the existing observable onboarding state machine; retain the persisted completion
  flag. Replay resets presentation state only, not completion or any export/permission setting.
- Seven pages: local processing, capture, editing/privacy, recognition/inspection,
  composition/pins, sharing, shortcuts. Completion occurs only on Skip or final Done.
- Native SwiftUI sections, SF Symbols, system type/color, scrollable page content and a fixed
  navigation footer. No new dependency, background task, network request or permission prompt.
- A menu-bar Feature tour command reopens the existing standard AppKit onboarding window.
- Repeating the command while the tour is visible brings that same window forward and preserves
  its page. Reopening a closed tour starts at the first page. Closing an unfinished tour never
  marks completion; completing replay never clears the original completion flag. A failed
  preference write retains the existing SettingsStore in-session behavior and warning; a later
  launch follows the value actually persisted. Login-item launch remains silent after completion.
- Keep stable identity for navigation, localization in the app String Catalog, and active-Space
  policy at construction. Test the real controller, not a separately constructed probe window.

## Testing Decisions

- Model seam: first launch, ordered navigation, Back bounds, Skip persistence, replay and
  unchanged automatic export preferences. Existing settings tests are prior art.
- App seam: bilingual onboarding E2E renders every page through the actual window factory,
  checks completion/replay and no capture permission requests. Existing shell/Space scenarios
  protect integration; remaining physical VoiceOver/TCC/display qualification stays explicit.
- Run the stable gate, bilingual native E2E and independent adversarial code/acceptance review.
- Verify an exported local-install bundle's metadata, signature, Hardened Runtime, distribution
  entitlements and exact installed files separately from UI and notarization claims.

## Out of Scope / protected decisions

Competitor recording/audio, always-on capture, history/archive, telemetry, proprietary cloud
accounts/collaboration and undocumented proprietary optimizations are not silently added under
the current safety contract. Missing safe capabilities are recorded individually after the
reference inventory; implementation requires their concrete acceptance and safety designs.
Physical performance, TCC and multi-display evidence cannot be replaced by synthetic tests.

## Further Notes

Primary sources: [Apple onboarding guidance](https://developer.apple.com/design/human-interface-guidelines/onboarding),
[Shottr](https://shottr.cc/), [CleanShot X](https://cleanshot.com/),
[Xcode 27.2 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes).
Reference bundle metadata is inspected read-only; no proprietary internal performance claim
is inferred from a product feature list or linked framework.
