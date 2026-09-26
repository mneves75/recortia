# Framepin — Open-source Shottr-alternative handoff

**Prepared:** September 26, 2026.  
**State:** Documentation-only specification. No macOS app, Xcode project, compiled binary, benchmark run, security audit, or executed test suite is included.  
**Name:** Framepin is a provisional internal codename, not a verified available brand.

## Start

Read SPEC.md for the product/engineering contract and AGENTS.md for implementation boundaries. Give the complete bundle to your coding agent and use START_HERE.md as the first prompt. The first action is repository/toolchain inspection and an M0 plan; application code changes require explicit approval.

## Contents

| File | Purpose |
|---|---|
| SPEC.md | Platform decisions, 16 requirement groups, scope, architecture, geometry, privacy/export, performance targets, and release conditions |
| AGENTS.md | Canonical agent instructions: authority, preflight, coding boundaries, verification, and truthful reporting |
| IMPLEMENTATION_PLAN.md | Seven milestones, 25 dependency-ordered task contracts, deliverables, and exit criteria |
| BACKLOG.json | Machine-readable version of all 25 unstarted tasks and deferred scope |
| ACCEPTANCE_TESTS.md | 29 acceptance scenarios covering pixels, permissions, scrolling, accessibility, privacy, and distribution |
| THREAT_MODEL.md | Sensitive assets, trust boundaries, risks, mitigations, and incident/release responsibilities |
| TOOLCHAIN.json | Proposed toolchain contract with unknown local environment fields deliberately left null |
| SOURCES.md | Primary research references and explicit limits of external verification |
| START_HERE.md | First coding-agent prompt, ready to paste |
| CLAUDE.md | Small pointer to the canonical AGENTS.md instructions |
| COMPLETE_HANDOFF.md | Single-file concatenation of the substantive documents for convenient agent context |
| MANIFEST.sha256 | Integrity hashes for the supplied bundle files; not a publisher signature |

## Selected direction

Native Swift/SwiftUI + AppKit; ScreenCaptureKit; Vision; macOS 15+ runtime; stable Xcode 27 with its Swift 6.4 compiler and Swift 6 mode, subject to actual Mac preflight. Apple Silicon first. Offline core, volatile screenshot sessions, secure flattened exports, no accounts or backend. MIT is the proposed project-code license.

The proposed distribution is a single notarized, Hardened Runtime-enabled direct-download app, not an App Sandbox-restricted app. That tradeoff requires M0 review; basic capture still must not require Accessibility/Input Monitoring. Automatic scrolling is separately consented; manual mode is mandatory.

## Reading boundaries

External facts were researched from public product and primary technical sources. All performance budgets are targets. The source website was reviewed, but Shottr was not run or disassembled. Exact SDK availability, physical-Mac behavior, compile results, permissions, signing, and names/domains remain unverified until the corresponding tasks are executed.

The bundle intentionally does not provide a fake application scaffold or prefilled successful test report. Runtime AI, uploads, project-file persistence, and other deferred features are not implementation authorization.
