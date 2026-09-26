#if DEBUG
    /// Every scenario, in run order. Ids are stable: they name screenshots and `-RecortiaE2EOnly`.
    @MainActor
    enum E2EScenarios {
        static let all: [E2EScenario] = [
            E2EScenario(id: "onboarding", title: "First-launch onboarding", run: ShellScenarios.onboarding),
            E2EScenario(id: "menu", title: "Menu bar menu", run: ShellScenarios.menu),
            E2EScenario(id: "settings", title: "Settings tabs", run: ShellScenarios.settings),
            E2EScenario(id: "region-overlay", title: "Region selection overlay", run: CaptureScenarios.regionOverlay),
            E2EScenario(id: "window-chooser", title: "Window chooser", run: CaptureScenarios.windowChooser),
            E2EScenario(id: "countdown", title: "Delayed capture countdown", run: CaptureScenarios.countdown),
            E2EScenario(id: "capture-editor", title: "Capture to editor", run: CaptureScenarios.captureToEditor),
            E2EScenario(id: "annotations", title: "Editor annotations and undo", run: EditorScenarios.annotations),
            E2EScenario(id: "redaction", title: "Redaction and RED-01", run: EditorScenarios.redaction),
            E2EScenario(id: "crop-resize", title: "Crop and resize", run: EditorScenarios.cropResize),
            E2EScenario(id: "ocr-qr", title: "Text recognition and QR", run: RecognitionScenarios.ocrAndQR),
            E2EScenario(id: "pixel-tools", title: "Loupe, ruler, and color picker", run: EditorScenarios.pixelTools),
            E2EScenario(id: "composition", title: "Composition and presentation", run: EditorScenarios.composition),
            E2EScenario(id: "export-sinks", title: "Copy, save, and drag out", run: OutputScenarios.exportSinks),
            E2EScenario(id: "pins", title: "Pins", run: OutputScenarios.pins),
            E2EScenario(id: "scrolling", title: "Scrolling capture", run: ScrollScenarios.scrolling),
            E2EScenario(id: "import", title: "Import and import errors", run: OutputScenarios.importFiles),
        ]
    }
#endif
