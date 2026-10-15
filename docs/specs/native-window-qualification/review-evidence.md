# Native window qualification evidence

Candidate base: `0781aedcbf4e743fd25b87b71356cbb5391aa86b`.
Environment: Xcode 27.0 (`27A266a`), Swift 6.4, macOS 27.2 seed host.
All commands select `/Applications/Xcode_27.app/Contents/Developer` and
`RECORTIA_TOOLCHAIN_MODE=stable`. The installed 0.12.0/build19 remains unchanged.

## Research and independent review

The Fable plan advisor required matched position/opacity controls and separate observations
of key ownership, responder assignment, visibility and activation. It rejected treating a
green rerun as a causal diagnosis. The deep branch audit and Standards/Spec source reviews
reported no new confirmed defect outside native qualification; those were source reviews,
not runtime acceptance of all branch behavior.

Apple documents that ordering alone does not make a window key, and that cooperative
activation is distinct from ordering. The implementation therefore preserves inactive
presentation and tests cooperative activation only as a separate positive control.

- [Window ordering](https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless())
- [Key-window ownership](https://developer.apple.com/documentation/appkit/nswindow/makekey())
- [Cooperative activation](https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation)
- [Occlusion state](https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.property)

## Controlled diagnostics

Evidence root: `.scratch/native-window-review-20261015/`.

- `baseline-focused.log`: original focused native command, English capture-focus FAIL and
  editor-presentation PASS; Portuguese both PASS. Activation controls were skipped. This
  does not establish a deterministic product defect.
- `matrix-summary.json` and `matrix-*.log`: declared onscreen/offscreen × alpha0/alpha1
  matrix, production unchanged. All editor cases passed, including offscreen cases.
  Two offscreen English capture cases failed key ownership; onscreen cases passed.
  These results do not establish one cause for both historical failures.
- `host-ready.json`: disposable standalone normal-app prototype established foreground,
  key ownership, visibility and active-Space membership using ordinary launch, then quit.
- `owned-fixture-focused.log`: reusing the accessory E2E bundle as a helper failed all four
  startup controls. No scenario reached product behavior.
- `standalone-fixture-focused.log`: the separate normal-app target compiled and its generated
  plist reported `LSUIElement=false`. All four startup controls still failed: the owned
  window was visible and opaque but lacked key ownership, activation and foreground state.
  This remains a fixture failure, not a product diagnosis. No deadline was increased.

Focused command:

```sh
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer RECORTIA_TOOLCHAIN_MODE=stable scripts/e2e.sh --lang all --only capture-focus,editor-presentation --unsigned
```

`standalone-fixture-lifecycle.log` records the next bounded English run after explicitly
selecting regular activation policy before the run loop and matching the prototype's screen
placement and window style. Both startup controls failed again, before product assertions.

`host-ready-recheck.json` repeats the previously successful minimal prototype using the same
ordinary `open -n -W -a` launch. It now reports `ready=false`, `active=false`, `key=false`,
`foregroundIsHost=false` and occlusion8192, with `visible=true` and `onActiveSpace=true`.
The prototype exits normally. The current graphical session therefore does not provide even
the known-good foreground control. These observations do not identify why activation was
declined, or prove that the helper implementation would pass in a suitable session.

Qualification is blocked pending a dedicated unlocked graphical desktop that can grant
ordinary activation to the owned synthetic control. No force activation, timeout increase,
TCC change, personal screen read or production focus change was attempted. The helper and
scenario changes remain an experimental candidate; final mutation controls, full gates and
final independent acceptance remain unrun. No new version, merge or release is justified.
