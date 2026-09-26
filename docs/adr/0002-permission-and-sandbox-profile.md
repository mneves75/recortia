# ADR-002: Permission and sandbox profile

**Status:** Accepted for v1 beta (owner approved implementation of all v1 milestones on 2026-09-26);
re-review before 1.0 public release.
**Date:** 2026-09-26
**Requirements:** FR-02, FR-10, FR-14 · **Verification:** PERM-01, PERM-02, SCR-03, REL-02

## Context

THREAT_MODEL.md requires this ADR to record why a single non-sandboxed target was chosen, whether
a sandboxed core was evaluated, which automatic-scrolling capabilities conflict with App Sandbox,
and whether deferring automatic scrolling would justify enabling the sandbox.

Automatic scrolling (FR-10) must deliver minimal scroll input to one chosen target app. On macOS
that needs either Accessibility APIs (`AXUIElement`) or posting events to another process
(`CGEvent.postToPid`), both gated by the Accessibility (TCC) privilege.

## Evidence

- Apple DTS: "It's not possible to use the Accessibility APIs from a sandboxed app"; there is no
  entitlement that enables it, and a manual grant in Privacy & Security does not help.
  ([Apple Developer Forums 756130](https://developer.apple.com/forums/thread/756130),
  [749494](https://developer.apple.com/forums/thread/749494),
  [707680](https://developer.apple.com/forums/thread/707680)).
- A sandboxed app never appears as grantable in Accessibility, and `AXIsProcessTrusted` stays false
  ([805556](https://developer.apple.com/forums/thread/805556)).
- Apple's "Protecting user data with App Sandbox" lists "use of accessibility APIs in assistive
  apps" among the capabilities unavailable in the sandbox (cited by DTS in the threads above).
- ScreenCaptureKit still capture, Vision, ImageIO, and user-selected file access all work without
  the Accessibility privilege; basic capture only needs Screen Recording.

Not tested locally: a sandboxed Recortia build. The Accessibility conclusion rests on Apple's own
statements above, not on a spike.

## Decision

1. Ship v1 as **one Developer ID–signed, notarized, Hardened Runtime app without App Sandbox**, as
   SPEC.md §2 proposes, because the sandbox makes automatic scrolling impossible.
2. Entitlements: none. No `com.apple.security.*` exceptions, no Apple Events, no camera,
   microphone, location, contacts, or network client entitlements. Hardened Runtime stays on with
   no runtime exceptions.
3. Permissions are just in time:
   - Screen Recording: requested on the first user-initiated capture, never at launch or during
     onboarding.
   - Accessibility: requested only when the user turns on automatic scrolling and starts an
     automatic session; manual scrolling never needs it.
   - Never: Input Monitoring, Full Disk Access, Apple Events automation.
4. In-app mitigations for running unsandboxed: no network code in the v1 core, no plugins or
   script execution, no privileged helper, a single minimal third-party dependency
   (KeyboardShortcuts 3.1.0, pinned by commit), user-selected destinations only.

## Rejected alternative

**Sandboxed core with automatic scrolling deferred.** Everything except automatic scrolling works
sandboxed, and the OS would enforce file and network limits. It was rejected for v1 because FR-10
makes automatic scrolling part of 1.0 scope. The owner can choose this profile later through an
ADR update; the code keeps automatic scrolling behind `AutoScroller` and a preference, so removing
it is contained.

## Consequences

- Hardened Runtime and TCC are not an OS filesystem or network sandbox. Compromised app code runs
  with the user's privileges. Release notes and Settings ▸ Privacy must not imply otherwise.
- Mac App Store and TestFlight distribution are impossible, since both require App Sandbox. Beta
  builds ship as notarized DMGs.
- TCC grants are tied to the code signature: Debug builds use the Apple Development identity so
  grants survive rebuilds; release builds use Developer ID.
