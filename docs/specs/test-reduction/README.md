# Test reduction (2026-10-16)

Owner request: "Só escreva um teste se ele realmente falhar quando o código estiver quebrado de uma
forma que importe. everything else is unnecessary bloat. try to reduce at least 40% of tests on
this project".

## Result

| Target | Before (cbe1153) | After | Removed |
| --- | ---: | ---: | ---: |
| DomainTests | 64 | 38 | 26 |
| FeaturesTests | 345 | 245 | 101 (+1 added) |
| ImagingTests | 174 | 126 | 48 |
| MacPlatformTests | 139 | 102 | 37 |
| `scripts/test-*.py` | 57 | 42 | 15 |
| **Total test functions** | **779** | **553** | **227 removed, 1 added (−29.0%)** |

A further 87 parameter cases were dropped from tests that stayed: variants that take no new
branch. The 40% target was not reached. Three read-only passes by a different model (GPT-6
Astra) reviewed one partition each. Each stopped at 28–32% of its partition. Below that line,
the remaining tests are the only guard of a meaningful break. Each pass recorded its reasons as
`shortfall_reason` in the evidence.

## Rules applied

- A test was removed when it duplicated another test, checked a detail rather than an outcome,
  used inputs the app cannot produce, tested public helpers the app never calls, or asserted an
  outcome that a bilingual native E2E scenario asserts on the same path.
- 64 of the removed tests cite E2E coverage. Hosted CI runs `scripts/check.sh --unsigned` and no
  native E2E, so for those outcomes only the owner's native run fails now.
- The unit test stays wherever it is the only CI guard of data loss, privacy or security.
  Kept by the author against the pruning passes: `FileSinkTests.refusesOverwrite`,
  `SettingsStoreTests.storesNoContent`,
  `ReleaseBinaryGateTests.test_marker_in_main_executable_is_rejected_by_app_and_by_executable_path`
  and `ScrollMatcherMemoryTests.measuresEquivalence`. Restored after the independent review
  (GPT-6 Astra, read-only): `ExportCoordinatorTests.cancelAutomaticBatch` and
  `ScrollSessionModelTests.screenPermissionDenied`. `ClipboardSinkTests.replacesPriorContents` now
  asserts the exact PNG bytes.
- Added: `EditorExportTests.saveOverwriteFollowsConfirmation`. No unit test failed when the editor
  or the export coordinator replaced a file without the save panel's confirmation.

## Mutation net

55 exact one-line source mutations cover data loss, secure masks, the sole ShareSnapshot route,
consent, stale results and the privacy epoch, decode bounds, undo budgets, scroll memory, the
release scripts and E2E isolation.

- Original suite (cbe1153): every mutation except F18 and F19 fails at least one test.
- Reduced suite: every mutation fails at least one test that `scripts/check.sh` runs. 31 were
  measured at 9dd9b54 (Features, Imaging, Domain), 21 at a195955 (MacPlatform, scripts and
  four Imaging/Domain probes) and the review's three at f6e85c4; later commits only add tests.
  M12, a freshness gate that passes without XcodeGen, is caught by
  `test-release-contract.py` after its own file's test was removed.
- The two overwrite mutations (F18, F19) were missed by the original suite. They are the red run
  for the added test.
- The review's three mutations (F20 explicit cancel, F21 initial permission denial, M19 truncated
  clipboard bytes) were missed at a195955, before the restoration, and are its red run.

## Out of scope, found while reviewing

- Public API with no production caller: `DesktopGeometry.selection`,
  `DesktopGeometry.display(containing:in:)`, the point-conversion helpers, `MacPlatform.RepeatRegion`
  and `SettingsStore.resetToDefaults`. Their tests were removed. The code itself is untouched.

Evidence (decisions, briefs, mutation set, runner and reports):
`.scratch/editor-window-size-20261016/test-reduction/`.
