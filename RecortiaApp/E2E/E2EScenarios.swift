#if DEBUG
    /// Every scenario, in run order. Ids are stable: they name screenshots and `-RecortiaE2EOnly`.
    @MainActor
    enum E2EScenarios {
        static let all: [E2EScenario] = [
            E2EScenario(id: "onboarding", title: "First-launch onboarding", run: ShellScenarios.onboarding),
            E2EScenario(id: "menu", title: "Menu bar menu", run: ShellScenarios.menu),
            E2EScenario(
                id: "space-policy", title: "Every window follows the active Space", run: SpaceScenarios.spacePolicy),
            E2EScenario(
                id: "other-spaces", title: "Capture leaves windows on other Spaces alone",
                run: DesktopScenarios.otherSpaces),
            E2EScenario(
                id: "screen-choice", title: "Windows open on the captured or pointer display",
                run: DesktopScenarios.screenChoice),
            E2EScenario(
                id: "countdown-cancel", title: "Countdown cancels by click and keyboard",
                run: DesktopScenarios.countdownCancel),
            E2EScenario(
                id: "held-shortcut-polling", title: "Held shortcuts are re-checked with backoff",
                run: DesktopScenarios.heldShortcutPolling),
            E2EScenario(
                id: "capture-menu-focus", title: "Dismissing the capture menu returns focus",
                run: DesktopScenarios.captureMenuFocus),
            E2EScenario(id: "settings", title: "Settings tabs", run: ShellScenarios.settings),
            E2EScenario(
                id: "quit-confirmation", title: "Quit asks before discarding edits",
                run: ShellScenarios.quitConfirmation),
            E2EScenario(id: "shortcuts", title: "macOS-style default shortcuts", run: ShortcutScenarios.defaults),
            E2EScenario(id: "capture-menu", title: "Capture menu (⇧⌘5)", run: ShortcutScenarios.captureMenu),
            E2EScenario(id: "region-overlay", title: "Region selection overlay", run: CaptureScenarios.regionOverlay),
            E2EScenario(
                id: "capture-focus", title: "Shortcut selection preserves the current application and Space",
                run: CaptureVisibilityScenarios.shortcutFocus),
            E2EScenario(id: "space-window", title: "Space switches to a window", run: ShortcutScenarios.spaceForWindow),
            E2EScenario(id: "window-chooser", title: "Window chooser", run: CaptureScenarios.windowChooser),
            E2EScenario(id: "countdown", title: "Delayed capture countdown", run: CaptureScenarios.countdown),
            E2EScenario(id: "capture-editor", title: "Capture to editor", run: CaptureScenarios.captureToEditor),
            E2EScenario(
                id: "editor-presentation", title: "Capture completion presents the real editor",
                run: CaptureVisibilityScenarios.editorPresentation),
            E2EScenario(
                id: "recapture", title: "Hide existing windows during recapture",
                run: CaptureVisibilityScenarios.recapture),
            E2EScenario(
                id: "capture-admission", title: "One capture session across modes",
                run: CaptureVisibilityScenarios.admission),
            E2EScenario(id: "annotations", title: "Editor annotations and undo", run: EditorScenarios.annotations),
            E2EScenario(
                id: "canvas-focus", title: "Space pan ends when keyboard ownership changes",
                run: EditorScenarios.canvasFocus),
            E2EScenario(
                id: "inspector-height", title: "Resize an image by its inspector height",
                run: EditorScenarios.inspectorHeight),
            E2EScenario(id: "redaction", title: "Redaction and RED-01", run: EditorScenarios.redaction),
            E2EScenario(id: "crop-resize", title: "Crop and resize", run: EditorScenarios.cropResize),
            E2EScenario(id: "ocr-qr", title: "Text recognition and QR", run: RecognitionScenarios.ocrAndQR),
            E2EScenario(id: "pixel-tools", title: "Loupe, ruler, and color picker", run: EditorScenarios.pixelTools),
            E2EScenario(id: "composition", title: "Composition and presentation", run: EditorScenarios.composition),
            E2EScenario(id: "export-sinks", title: "Copy, save, and drag out", run: OutputScenarios.exportSinks),
            E2EScenario(
                id: "automatic-export", title: "Automatic export cancellation, busy notice and GitHub",
                run: AutomaticExportScenarios.regression),
            E2EScenario(id: "pins", title: "Pins", run: OutputScenarios.pins),
            E2EScenario(id: "scrolling", title: "Scrolling capture", run: ScrollScenarios.scrolling),
            E2EScenario(id: "import", title: "Import and import errors", run: OutputScenarios.importFiles),
            E2EScenario(
                id: "import-admission", title: "One import read/decode across documents and layers",
                run: OutputScenarios.importAdmission),
            E2EScenario(
                id: "editor-notices", title: "Editor notices are announced and failures stay until dismissed",
                run: EditorFixScenarios.notices),
            E2EScenario(
                id: "github-destination", title: "Changing the destination removes the old token",
                run: EditorFixScenarios.githubDestination),
        ]
    }
#endif
