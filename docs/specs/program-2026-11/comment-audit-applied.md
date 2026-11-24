# Comment audit applied 2026-11-19

Status: applied in one comment-only commit on `feat/refresh-2026-11`. Input:
[`comment-audit.md`](comment-audit.md) (239 rows at `b2726b4`). Every row outside the deferred files
was rechecked against the code; none was taken on trust.

| Verdict | Rows |
|---|---:|
| Pruned | 91 |
| Rewritten | 68 |
| Kept against the audit | 43 (40 PRUNE, 3 REWRITE) |
| Not edited, possible defect | 1 |
| Deferred (files owned by other branches) | 36 |
| **Total** | **239** |

Rewrites state what the code does now. Where the audit's suggested text was accurate it was used,
often tightened to keep the original comment's structure; where the original held a platform quirk
or rationale the suggestion dropped, that part stayed. Notable cases:

- `Packages/RecortiaKit/Sources/Domain/StateMachines.swift:159–161`: kept line 159 summary, rewrote 160-161
- `Packages/RecortiaKit/Sources/Imaging/QRBitstream.swift:3–11`: kept the Vision payloadData quirk; fixed the UTF-8 claim
- `Packages/RecortiaKit/Sources/MacPlatform/FileSink.swift:185–188`: kept the macOS 27 umask quirk, dropped history
- `Packages/RecortiaKit/Tests/ImagingTests/RenderRedactionMetamorphicTests.swift:314–316`: dropped "now" history, kept the rationale
- `RecortiaApp/App/AppModel.swift:38-44`: kept the hook facts, dropped "left for the owners" history
- `Packages/RecortiaKit/Sources/Domain/StateMachines.swift:90` and `:159` keep their state-machine
  summary lines (coordinator rule).

## Kept against the audit

| Path and line | Audit verdict | Reason kept |
|---|---|---|
| `Packages/RecortiaKit/Sources/Domain/StateMachines.swift:90` | PRUNE | State-machine summary above the enum; rule keeps it. |
| `Packages/RecortiaKit/Sources/Features/CaptureCoordinator.swift:306` | PRUNE | Says registerCapture canonicalizes; fail-closed, no invented image. |
| `Packages/RecortiaKit/Sources/Features/EditorModel+Composition.swift:280` | PRUNE | Gives the units of `amount` (radius or block size). |
| `Packages/RecortiaKit/Sources/Features/EditorModel+Gestures.swift:139` | PRUNE | "No button" is a fact the signature lacks. |
| `Packages/RecortiaKit/Sources/Features/EditorModel.swift:37` | PRUNE | Points the stored state to the extension file that owns it. |
| `Packages/RecortiaKit/Sources/Features/EditorModel.swift:44` | PRUNE | Points the stored state to the extension file that owns it. |
| `Packages/RecortiaKit/Sources/Features/EditorModel.swift:48` | PRUNE | Points the stored state to the extension file that owns it. |
| `Packages/RecortiaKit/Sources/Features/EditorModel.swift:361` | PRUNE | Names why geometry can be missing; not visible in the guard. |
| `Packages/RecortiaKit/Sources/Features/EditorTypes.swift:92` | PRUNE | Public type doc: "selectable" is not visible in the signature. |
| `Packages/RecortiaKit/Sources/Features/PinsModel.swift:11` | PRUNE | Public error case doc ties it to the exact limit constant. |
| `Packages/RecortiaKit/Sources/Features/QuitAfterLastWindow.swift:3` | PRUNE | "In the menu bar" is a fact the case name lacks. |
| `Packages/RecortiaKit/Sources/Features/Services.swift:175` | PRUNE | Protocol requirement contract for implementers; `reset` alone is vague. |
| `Packages/RecortiaKit/Sources/Imaging/DecodeContainerHeaders.swift:5` | PRUNE | States the accepted-format policy (FR-03), not only the cases. |
| `Packages/RecortiaKit/Sources/Imaging/RenderEngine.swift:390` | PRUNE | Summarizes a long function whose name `present` is vague. |
| `Packages/RecortiaKit/Sources/MacPlatform/AutoScroller.swift:58` | PRUNE | States the priority-order rule: most fundamental reason first. |
| `Packages/RecortiaKit/Sources/MacPlatform/CaptureExclusion.swift:4` | PRUNE | Says Recortia itself is excluded separately; not visible here. |
| `Packages/RecortiaKit/Sources/MacPlatform/DragOutProvider.swift:15` | PRUNE | Accurate: revocation before the receiver's request yields this case. |
| `Packages/RecortiaKit/Tests/FeaturesTests/ImportCoordinatorTests.swift:130` | PRUNE | Explains why isEnabled stays true: it mirrors the system state. |
| `Packages/RecortiaKit/Tests/FeaturesTests/ScrollSessionModelEndingTests.swift:138` | REWRITE | Accurate: four steps precede the end frame; rewrite adds nothing. |
| `Packages/RecortiaKit/Tests/FeaturesTests/ScrollSessionModelEndingTests.swift:185` | PRUNE | `deliver()` alone does not say the page moved; the intent does. |
| `Packages/RecortiaKit/Tests/ImagingTests/RenderCompositionTests.swift:129` | PRUNE | Trailing comment on a code line; the comment-only rule forbids touching it. |
| `Packages/RecortiaKit/Tests/ImagingTests/RenderRedactionMetamorphicTests.swift:205` | PRUNE | Trailing comment on a code line; the comment-only rule forbids touching it. |
| `Packages/RecortiaKit/Tests/ImagingTests/RenderRedactionMetamorphicTests.swift:206` | PRUNE | Trailing comment on a code line; the comment-only rule forbids touching it. |
| `Packages/RecortiaKit/Tests/ImagingTests/RenderRedactionMetamorphicTests.swift:207` | PRUNE | Trailing comment on a code line; the comment-only rule forbids touching it. |
| `Packages/RecortiaKit/Tests/ImagingTests/RenderRedactionMetamorphicTests.swift:208` | PRUNE | Trailing comment on a code line; the comment-only rule forbids touching it. |
| `Packages/RecortiaKit/Tests/ImagingTests/RenderRedactionMetamorphicTests.swift:209` | PRUNE | Trailing comment on a code line; the comment-only rule forbids touching it. |
| `Packages/RecortiaKit/Tests/ImagingTests/ScrollNarrowColumnTests.swift:18` | PRUNE | Contrasts column width with the full-width chrome above it. |
| `Packages/RecortiaKit/Tests/MacPlatformTests/ScreenCaptureServiceTests.swift:10` | PRUNE | Says errors are built at throw time; not visible from the cases. |
| `RecortiaApp/App/AppActions.swift:3` | PRUNE | Says which surfaces trigger the commands: menu bar and shortcuts. |
| `RecortiaApp/App/AppModel.swift:76` | PRUNE | The closure type `(Int) -> Bool` hides what the Int means. |
| `RecortiaApp/App/AppPresence.swift:25` | PRUNE | "Since the last refresh" gives the flag's lifetime. |
| `RecortiaApp/App/GlobalShortcuts.swift:12` | PRUNE | Explains the vague `captureMenu` name and its default shortcut. |
| `RecortiaApp/App/LiveServices.swift:140` | PRUNE | Gives the rationale for mapping `.invalidOptions` to an encode failure. |
| `RecortiaApp/App/MessagePresenter.swift:48` | PRUNE | "True means quit" gives the Bool return's meaning. |
| `RecortiaApp/App/RecortiaApp.swift:40-41` | REWRITE | Accurate: "whatever it was launched with" already covers fall-through. |
| `RecortiaApp/App/RecortiaApp.swift:53-54` | PRUNE | States the process exits with its result; brief keeps it. |
| `RecortiaApp/E2E/E2EPanelProbe.swift:51` | PRUNE | "Child side" places the function in the two-process probe. |
| `RecortiaApp/E2E/Scenarios+AutomaticSave.swift:160` | PRUNE | Says why `activate()` runs: the failed capture's editor is in front. |
| `RecortiaApp/E2E/Scenarios+EditorFixes.swift:254` | PRUNE | States the app's own resolver renews the preference; brief keeps it. |
| `RecortiaApp/E2E/Scenarios+LastWindow.swift:305-307` | REWRITE | Explains why `press` is avoided: its synthesized click needs a key window. |
| `RecortiaApp/E2E/Scenarios+LastWindow.swift:537` | PRUNE | "Child side" places the function in the two-process probe. |
| `RecortiaApp/E2E/Scenarios+Shell.swift:457` | PRUNE | Says the content mirrors SettingsWindowController's construction. |
| `RecortiaApp/E2E/Scenarios+Spaces.swift:34` | PRUNE | Groups app-built windows against the framework stand-in below. |

## Deferred

Rows in files that other branches own (Editor, the listed E2E scenarios, RecortiaFixtures,
`Domain/Document.swift`, `Features/ImportCoordinator.swift`, `project.yml`). Recheck them there.

- `Packages/RecortiaKit/Sources/Domain/Document.swift:251` (PRUNE)
- `Packages/RecortiaKit/Sources/Features/ImportCoordinator.swift:14` (PRUNE)
- `Packages/RecortiaKit/Sources/RecortiaFixtures/ContainerCrafting.swift:26` (PRUNE)
- `Packages/RecortiaKit/Sources/RecortiaFixtures/ContainerInspector.swift:23` (REWRITE)
- `Packages/RecortiaKit/Sources/RecortiaFixtures/ContainerInspector.swift:77` (PRUNE)
- `Packages/RecortiaKit/Sources/RecortiaFixtures/ContainerInspector.swift:82` (REWRITE)
- `Packages/RecortiaKit/Sources/RecortiaFixtures/QRFixture.swift:73` (REWRITE)
- `Packages/RecortiaKit/Sources/RecortiaFixtures/QRFixture.swift:102` (PRUNE)
- `Packages/RecortiaKit/Sources/RecortiaFixtures/ScrollPage.swift:280` (REWRITE)
- `Packages/RecortiaKit/Sources/RecortiaFixtures/TextCorpus.swift:51` (PRUNE)
- `RecortiaApp/E2E/Scenarios+Appearance.swift:9-15` (REWRITE)
- `RecortiaApp/E2E/Scenarios+Appearance.swift:303` (PRUNE)
- `RecortiaApp/E2E/Scenarios+Appearance.swift:410` (PRUNE)
- `RecortiaApp/E2E/Scenarios+EditorToolbar.swift:237` (PRUNE)
- `RecortiaApp/E2E/Scenarios+EditorWindowSize.swift:6-9` (REWRITE)
- `RecortiaApp/E2E/Scenarios+EditorWindowSize.swift:21` (PRUNE)
- `RecortiaApp/E2E/Scenarios+Inspector.swift:335` (PRUNE)
- `RecortiaApp/Editor/EditorCanvasView.swift:146` (REWRITE)
- `RecortiaApp/Editor/EditorInspectorView.swift:7-9` (REWRITE)
- `RecortiaApp/Editor/EditorInspectorView.swift:22` (PRUNE)
- `RecortiaApp/Editor/EditorInspectorView.swift:255` (PRUNE)
- `RecortiaApp/Editor/EditorInspectorView.swift:350` (PRUNE)
- `RecortiaApp/Editor/EditorInspectorView.swift:576` (PRUNE)
- `RecortiaApp/Editor/EditorPreview.swift:58` (PRUNE)
- `RecortiaApp/Editor/EditorRootView.swift:77` (PRUNE)
- `RecortiaApp/Editor/EditorRootView.swift:180` (PRUNE)
- `RecortiaApp/Editor/EditorRootView.swift:254` (PRUNE)
- `RecortiaApp/Editor/EditorStrings.swift:69` (PRUNE)
- `RecortiaApp/Editor/EditorStrings.swift:113` (PRUNE)
- `RecortiaApp/Editor/EditorStrings.swift:220` (PRUNE)
- `RecortiaApp/Editor/EditorWindowManager.swift:7` (PRUNE)
- `RecortiaApp/Editor/EditorWindowManager.swift:24` (PRUNE)
- `RecortiaApp/Editor/EditorWindowManager.swift:36` (PRUNE)
- `RecortiaApp/Editor/EditorWindowManager.swift:109` (REWRITE)
- `RecortiaApp/Editor/EditorWindowManager.swift:171` (REWRITE)
- `project.yml:101` (REWRITE)

## Possible defects

- `RecortiaApp/App/AppPresence.swift:89-91`: the comment says `minimizedWindow` is "the most recent
  minimized switchable window, restored by a Dock click", but the code takes
  `NSApp.windows.last { isSwitchable && isMiniaturized }`. `NSApp.windows` carries no
  minimization order, so a Dock click may restore a window other than the last one minimized.
  Comment left unchanged: the audit's rewrite would document the lookup and hide the question.
  Decide whether restoring the most recently minimized window is the intended behavior.

## Proof

- Comment-only check over `git diff -U0 -- . ':!docs'`: every added or removed line is blank, a
  `//` comment, a `#` comment in a shell, Python or YAML file, or a line of the edited
  `scripts/tests-report.py` module docstring.
- `xcrun swift format lint --strict --recursive --parallel Packages/RecortiaKit/Sources
  Packages/RecortiaKit/Tests RecortiaApp RecortiaUITests`: exit 0, no output.
- `swift build --package-path Packages/RecortiaKit`: build complete.
- `zsh -n scripts/e2e.sh` and `ast.parse` of the four edited Python scripts: pass.
