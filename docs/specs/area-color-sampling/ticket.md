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

Status: implemented; parent integration and synthetic native UI evidence pending. Source-red
evidence: `.scratch/area-color-sampling/02-sampler-red.log` (`averageColor` absent) and
`04-editor-red.log` (sample-size API absent). Focused final suites passed: `06-sampler-final.log`
(10 tests), `07-editor-final.log` (13 tests). Strict format passed in `08-format.log` (empty log,
exit 0). Stable Xcode 27.1 / Swift 6.4 / macOS 27.0 SDK on macOS 27.2 arm64.
