# Ticket: bounded color-picker area average

Requirement IDs: FR-11, PIX-01, RED-02, RED-03.

Deliver one bounded sampler extension, typed 1×1 / 3×3 / 5×5 choices, editor selection state,
localized inspector controls, and behavioral regressions. Keep nearest-pixel hover/loupe,
sanitized-base admission and redaction invalidation authoritative.

Acceptance:

1. Literal mixed 3×3 and 5×5 fixtures return the specified encoded sRGB mean.
2. Bounds clip without padding; unsupported/extreme radius and coordinates return nil.
3. Alpha is averaged; hidden transparent RGB contributes nothing; transparent output RGB is zero.
4. Default 1×1 remains compatible. Editor size changes require a new explicit pick and copy.
5. A stale/redacted base cannot sample or copy an earlier sensitive result.
6. The native picker labels and help exist in EN/PT-BR.

Focused verification: stable-Xcode `swift test --package-path Packages/RecortiaKit --filter
PixelSamplerTests`, then `--filter EditorPixelToolsTests`, plus strict `swift format lint` on
owned changed Swift files. Parent owns full app builds, synthetic UI evidence and independent review.

Status: source verified; awaiting manual validation and stable release qualification. Parent
integration, bilingual synthetic UI and independent code acceptance PASS. Overall acceptance
BLOCKED; see ../feature-discovery/acceptance-verdict.md. Source-red
evidence: `.scratch/area-color-sampling/02-sampler-red.log` (`averageColor` absent) and
`04-editor-red.log` (sample-size API absent). Focused final suites passed: `06-sampler-final.log`
(10 tests), `15-binding-green.log` (14 tests). Strict format passed in `16-binding-format.log`
(exit 0). Xcode 27.1 RC 27A9275 / Swift 6.4 / macOS 27.0 SDK on macOS 27.2 seed arm64;
this is development evidence, not stable qualification.
