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

/// Native Settings window (FR-14): one tab per area, standard controls, system typography.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: model.settings, loginItem: model.features?.loginItem)
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutsSettingsTab(status: model.shortcutStatus)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            CaptureSettingsTab(settings: model.settings)
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
            ExportSettingsTab(settings: model.settings, folders: model.features?.services.folders)
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            PrivacySettingsTab()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            OCRSettingsTab(settings: model.settings, languages: model.features?.ocrLanguages)
                .tabItem { Label("Text Recognition", systemImage: "text.viewfinder") }
            PinsSettingsTab(settings: model.settings)
                .tabItem { Label("Pins", systemImage: "pin") }
            ScrollingSettingsTab(settings: model.settings, accessibility: model.features?.services.accessibility)
                .tabItem { Label("Scrolling", systemImage: "arrow.up.and.down.text.horizontal") }
        }
        .frame(width: 560)
        .frame(minHeight: 360)
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
                        "Open Framepin at login",
                        isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    if loginItem.lastErrorOccurred {
                        Text(
                            "macOS did not change the login item. Check System Settings › General › Login Items & Extensions."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Toggle("Open Framepin at login", isOn: .constant(false))
                        .disabled(true)
                    Text("Not available in this build.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Allow update checks", isOn: settings.binding(\.updateChecksEnabled))
                Text("Off by default. While it is off, Framepin makes no network requests.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem?.refresh() }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsTab: View {
    let status: ShortcutStatusModel

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutBinding.all) { binding in
                    ShortcutRecorderRow(binding: binding, status: status)
                }
            } footer: {
                Text(
                    "No shortcut is assigned until you record one. Framepin warns about conflicts with macOS and menu shortcuts it can detect, but it cannot know every shortcut other apps use."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
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
                    "Both are off by default. Automatic copy and save happen right after the capture, before any edit or redaction you make later, and cannot be taken back from other apps."
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
        guard panel.runModal() == .OK, let url = panel.url, let bookmark = try? url.bookmarkData() else { return }
        settings.update { $0.preferredSaveFolderBookmark = bookmark }
    }
}

// MARK: - Privacy

struct PrivacySettingsTab: View {
    var body: some View {
        Form {
            Section("What stays on this Mac") {
                Text(
                    "Screenshots, edits, and recognized text exist only in memory while you work. Framepin keeps no screenshot history and uploads nothing."
                )
                Text(
                    "Framepin saves only these settings. It writes an image to disk or the clipboard only when you choose Copy, Save, drag an image out, or turn on automatic export."
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
                    "Redaction applies to the image you export from Framepin. It cannot find every secret, and it cannot remove copies you exported or shared earlier."
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
                Text("Pins stay until you close them and are not restored after Framepin quits.")
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
                    "Automatic scrolling needs Accessibility permission so Framepin can scroll the area you chose. It sends only scroll actions to that area, never keystrokes or clicks. Manual scrolling always works without it."
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
        SettingsView(model: PreviewSupport.appModel())
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
