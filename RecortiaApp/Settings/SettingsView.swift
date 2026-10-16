import AppKit
import Domain
import Features
import SwiftUI

extension SettingsStore {
    /// A SwiftUI binding to one preference; writes go through `update`, which clamps and persists.
    func binding<Value>(_ keyPath: WritableKeyPath<Preferences, Value> & Sendable) -> Binding<Value> {
        Binding(
            get: { self.preferences[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    let settings: SettingsStore
    let loginItem: LoginItemModel?

    var body: some View {
        Form {
            Section {
                if let loginItem {
                    Toggle(
                        "Open Recortia at login",
                        isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    if loginItem.lastErrorOccurred {
                        Text(
                            "macOS did not change the login item. Check System Settings › General › Login Items & Extensions."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Toggle("Open Recortia at login", isOn: .constant(false))
                        .disabled(true)
                    Text("Not available in this build.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem?.refresh() }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsTab: View {
    let status: ShortcutStatusModel
    let onRestoreDefaults: () -> Void

    var body: some View {
        Form {
            if status.isHoldingAny {
                Section {
                    MacOSShortcutsNotice()
                }
            }
            Section {
                ForEach(ShortcutBinding.all) { binding in
                    ShortcutRecorderRow(binding: binding, status: status)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "The defaults match the macOS Screenshot app: ⇧⌘3 captures the display, ⇧⌘4 a region (press Space for a window), and ⇧⌘5 shows every capture mode. Recortia warns about conflicts with macOS and menu shortcuts it can detect, but it cannot know every shortcut other apps use."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Restore Defaults", action: onRestoreDefaults)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { status.noteUserAttention() }
    }
}

// MARK: - Capture

struct CaptureSettingsTab: View {
    let settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Stepper(value: settings.binding(\.captureDelaySeconds), in: 0...CaptureRequest.maxDelaySeconds) {
                    Text("Delay: \(settings.preferences.captureDelaySeconds) s")
                }
                Text(
                    "Used by Capture with Delay. When set to 0, Capture with Delay waits \(CaptureCoordinator.fallbackDelaySeconds) seconds."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show the pointer in captures", isOn: settings.binding(\.captureShowsCursor))
                Toggle("Include window shadow", isOn: settings.binding(\.captureIncludesWindowShadow))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Export

struct ExportSettingsTab: View {
    let settings: SettingsStore
    let folders: (any SaveFolderService)?

    var body: some View {
        Form {
            Section {
                Picker("Format", selection: settings.binding(\.defaultExportFormat)) {
                    Text("PNG").tag(ExportFormatKind.png)
                    Text("JPEG").tag(ExportFormatKind.jpeg)
                }
                if settings.preferences.defaultExportFormat == .jpeg {
                    Slider(value: settings.binding(\.jpegQuality), in: 0.1...1, step: 0.05) {
                        Text("JPEG quality")
                    } minimumValueLabel: {
                        Text("Smaller")
                    } maximumValueLabel: {
                        Text("Better")
                    }
                    .accessibilityValue(
                        Text(settings.preferences.jpegQuality, format: .percent.precision(.fractionLength(0))))
                }
                Picker("Scale", selection: settings.binding(\.defaultExportScale)) {
                    Text(0.5, format: .percent).tag(0.5)
                    Text(1.0, format: .percent).tag(1.0)
                    Text(2.0, format: .percent).tag(2.0)
                }
                Text("Copy Image always places a PNG on the clipboard.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                if settings.loadIssue == .unverifiedConsent {
                    Label(
                        "Automatic copy, save, and scrolling were turned off because their saved settings could not be verified. Turn them on again if you want them.",
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.callout)
                }
                Toggle("Copy automatically after capture", isOn: settings.binding(\.autoCopy))
                Toggle("Save automatically after capture", isOn: settings.binding(\.autoSave))
                HStack {
                    Text("Save folder")
                    Spacer()
                    Text(folderDescription)
                        .foregroundStyle(.secondary)
                    Button("Choose…", action: chooseFolder)
                }
            } header: {
                Text("Automatic export")
            } footer: {
                Text(
                    "Both are off by default. Automatic copy and save apply to still captures: they happen right after the capture, before any edit or redaction you make later, and cannot be taken back from other apps. Scrolling captures open for review instead."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private var folderDescription: String {
        guard let bookmark = settings.preferences.preferredSaveFolderBookmark else {
            return String(localized: "None")
        }
        if let url = folders?.resolveFolder(bookmark: bookmark) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return folders == nil ? String(localized: "Chosen") : String(localized: "Unavailable")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose where automatic saves go.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData()
            settings.update { $0.preferredSaveFolderBookmark = bookmark }
        } catch {
            MessagePresenter.present(
                UserMessage(
                    title: String(localized: "The folder could not be saved"),
                    detail: String(
                        localized: "Recortia could not remember access to that folder. Choose another folder.")))
        }
    }
}

// MARK: - Privacy

struct PrivacySettingsTab: View {
    var body: some View {
        Form {
            Section("What stays on this Mac") {
                Text(
                    "Recortia keeps no local screenshot history. Optional GitHub upload sends still captures only after separate setup and consent."
                )
                Text(
                    "Recortia saves only these settings. It writes an image to disk or the clipboard only when you choose Copy, Save, drag an image out, or turn on automatic export."
                )
            }
            Section("Redaction") {
                Text(
                    "Solid redaction replaces the covered pixels with an opaque color in the exported image. It is the secure tool."
                )
                Text(
                    "Blur and pixelation are cosmetic. They can leave text recoverable, so do not use them to hide secrets."
                )
                Text(
                    "Redaction applies to the image you export from Recortia. It cannot find every secret, and it cannot remove copies you exported or shared earlier."
                )
            }
            Section("Permissions") {
                Text(
                    "Screen Recording is requested the first time you capture. Accessibility is requested only if you turn on automatic scrolling."
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - OCR

struct OCRSettingsTab: View {
    let settings: SettingsStore
    let languages: OCRLanguagesModel?

    var body: some View {
        Form {
            Section {
                Picker("Copied text", selection: settings.binding(\.ocrTextMode)) {
                    Text("Keep line breaks").tag(OCRTextMode.preserveLineBreaks)
                    Text("Join into one line").tag(OCRTextMode.normalizedWhitespace)
                    Text("Exactly as recognized").tag(OCRTextMode.raw)
                }
                Text("Text is recognized on this Mac and never corrected automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Available languages") {
                languageList
            }
        }
        .formStyle(.grouped)
        .task { await languages?.load() }
    }

    @ViewBuilder
    private var languageList: some View {
        switch languages?.state {
        case .loaded(let list):
            ForEach(list, id: \.maximalIdentifier) { language in
                Text(
                    Locale.current.localizedString(forIdentifier: language.maximalIdentifier)
                        // Vision reports some identifiers (such as "vi-VT") that name no region.
                        ?? language.languageCode.flatMap {
                            Locale.current.localizedString(forLanguageCode: $0.identifier)
                        }
                        ?? language.minimalIdentifier)
            }
        case .loading, .notLoaded:
            ProgressView()
                .accessibilityLabel(Text("Loading languages"))
        case .unavailable, nil:
            Text("Language information is not available.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pins

struct PinsSettingsTab: View {
    let settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Slider(value: settings.binding(\.pinDefaultOpacity), in: SettingsStore.opacityRange, step: 0.05) {
                    Text("Default opacity")
                } minimumValueLabel: {
                    Text(SettingsStore.opacityRange.lowerBound, format: .percent)
                } maximumValueLabel: {
                    Text(SettingsStore.opacityRange.upperBound, format: .percent)
                }
                .accessibilityValue(
                    Text(settings.preferences.pinDefaultOpacity, format: .percent.precision(.fractionLength(0))))
                Text("Pins stay until you close them and are not restored after Recortia quits.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Scrolling

struct ScrollingSettingsTab: View {
    let settings: SettingsStore
    let accessibility: (any AccessibilityPermissionService)?
    @State private var isTrusted = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Scroll automatically",
                    isOn: Binding(
                        get: { settings.preferences.automaticScrollingEnabled },
                        set: { enabled in
                            settings.update { $0.automaticScrollingEnabled = enabled }
                            if enabled, let accessibility, !accessibility.isTrusted {
                                accessibility.requestWithPrompt()
                            }
                            refresh()
                        })
                )
                .disabled(accessibility == nil)
                Text(
                    "Automatic scrolling needs Accessibility permission so Recortia can scroll the area you chose. It sends only scroll actions to that area, never keystrokes or clicks. Manual scrolling always works without it."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Accessibility") {
                    if accessibility == nil {
                        Text("Not available in this build.")
                    } else {
                        Text(isTrusted ? "Allowed" : "Not allowed")
                    }
                }
                if accessibility != nil {
                    Button("Check Again", action: refresh)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        isTrusted = accessibility?.isTrusted ?? false
    }
}

#if DEBUG
    #Preview("Settings") {
        SettingsPreview()
    }

    /// The production tab controller, as the Settings window shows it.
    private struct SettingsPreview: NSViewControllerRepresentable {
        func makeNSViewController(context: Context) -> NSTabViewController {
            SettingsWindowController.makeTabs(model: PreviewSupport.appModel())
        }
        func updateNSViewController(_ controller: NSTabViewController, context: Context) {}
    }

    #Preview("General with login item") {
        GeneralSettingsTab(settings: PreviewSupport.settings(), loginItem: PreviewSupport.loginItem())
            .frame(width: 560)
    }

    #Preview("Export") {
        let settings = PreviewSupport.settings()
        settings.update { $0.defaultExportFormat = .jpeg }
        return ExportSettingsTab(settings: settings, folders: nil)
            .frame(width: 560, height: 520)
    }

    #Preview("Text Recognition") {
        OCRSettingsTab(settings: PreviewSupport.settings(), languages: PreviewSupport.ocrLanguages())
            .frame(width: 560, height: 400)
    }

    #Preview("Privacy") {
        PrivacySettingsTab()
            .frame(width: 560, height: 520)
    }

    #Preview("Capture, Pins, Scrolling") {
        VStack {
            CaptureSettingsTab(settings: PreviewSupport.settings())
            PinsSettingsTab(settings: PreviewSupport.settings())
            ScrollingSettingsTab(settings: PreviewSupport.settings(), accessibility: nil)
        }
        .frame(width: 560, height: 900)
    }
#endif
