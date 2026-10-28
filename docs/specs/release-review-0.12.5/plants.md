# Planted reverts

Every instrument in this release was reverted on purpose and watched fail, then restored. The
outputs below are copied from the runs; each one is a control that would be missing if the check
were decorative.

## 1. Seam markers: one colour instead of a keyline

Revert: replace the white under-stroke plus black core with a single `Color.primary` stroke.

```text
[e2e] FAIL appearance-contrast (3033 ms)
[e2e]     ✗ seam markers keep contrast on a dark page in light appearance: strongest 1.08:1 over 1728 changed pixels
[e2e]     ✗ seam markers keep contrast on a light page in dark appearance: strongest 1.06:1 over 1728 changed pixels
0/1 scenarios passed
```

Restored, the same scenario reports per band: 19.17:1 dark page, 19.60:1 light page, 5.32:1 mid
grey, in both appearances, with two bands at 91% of the preview width.

## 2. Review window: the controller stops being the delegate

Revert: delete `window.delegate = self` in `ScrollUIController.makeReviewWindow()`.

```text
[e2e] FAIL appearance-contrast (3032 ms)
[e2e]     ✗ the controller is the window's delegate, so close is answered: nil
```

## 3. Isolation scan: one spelling per rule

Revert: remove the `NSPasteboard.generalByName` rule, then separately the `UserDefaults.suiteName`
rule, and run the suite's own planted-control test.

```text
CONTROL-1 remove NSPasteboard.generalByName rule -> test passes? False (must be False)
CONTROL-2 remove UserDefaults.suiteName rule -> test passes? False (must be False)
```

## 4. Defaults-domain guard: the guard moves into a comment

Revert: keep the guard's text on `//` lines and fall back to `Bundle.main.bundleIdentifier`, in a
throwaway tree.

```text
CONTROL-3 commented-out guard -> test passes? False (must be False)
```

## 5. Watchdog: a run that stops producing output

Revert: none. This is the new guard's own positive control, with a fixture app that sleeps and
writes nothing.

```text
e2e[en]: no runner output for 1s; stopping this run as a hang
e2e[en]: no report (exit 143: crash or stopped after 3600s ceiling, 1s silence)
```

## 6. Gate inventory: `tests.json` goes stale

Observed without planting anything: after the E2E evidence improved, the gate refused to pass.

```text
== gate inventory
tests-report: tests.json says e2e is incomplete, the evidence says passed
```

And the generated file's own tests fail when a caller stops invoking its test, when a
`scripts/test-*.py` is named by no gate, and when a recorded status disagrees with the evidence
(`scripts/test-tests-report.py`, 9 tests).
