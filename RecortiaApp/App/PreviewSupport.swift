#if DEBUG
    import CoreGraphics
    import Domain
    import Features
    import Foundation
    import Imaging
    import MacPlatform

    /// Debug-only stand-ins for Xcode previews. They never touch the screen, clipboard, TCC, or
    /// UserDefaults, and they are compiled out of Release builds.
    enum PreviewSupport {
        static func settings() -> SettingsStore {
            SettingsStore(storage: PreviewPreferenceStorage(), integrity: PreviewPreferenceIntegrity())
        }

        /// Settings' folder controls get a chooser that cancels: no open panel, no bookmark.
        static func appModel() -> AppModel {
            AppModel(
                settings: settings(), services: services(), shortcutRegistry: PreviewShortcutRegistry(),
                chooseSaveFolder: { nil })
        }

        /// Inert services for previews and the E2E last-window probe: nothing reaches the screen,
        /// clipboard, files, keychain, network or TCC.
        static func services() -> AppServices {
            let system = PreviewSystem(), assets = PreviewEditorAssets(), sink = PreviewEditorSink()
            let detector = PreviewEditorQR()
            return AppServices(
                capture: system, screenPermission: system, accessibility: system, assets: assets, input: assets,
                renderer: PreviewEditorRenderer(), exporter: PreviewEditorExporter(), clipboard: sink, files: sink,
                drag: sink, printer: sink, folders: sink, textRecognition: PreviewTextRecognition(),
                qrDecoder: detector, sensitiveText: detector, scrollFrames: system, stitcher: LiveStitcher(),
                autoScroller: nil, loginItem: PreviewLoginItem(), clock: PreviewEditorClock())
        }

        static func shortcutStatus(failing: Set<String> = [], held: Set<String> = []) -> ShortcutStatusModel {
            let probe = PreviewShortcutRegistry()
            probe.failing = failing
            probe.held = held
            let model = ShortcutStatusModel(registry: probe, names: ShortcutBinding.names)
            model.refreshAll()
            return model
        }

        static func loginItem() -> LoginItemModel {
            LoginItemModel(service: PreviewLoginItem())
        }

        static func ocrLanguages() -> OCRLanguagesModel {
            OCRLanguagesModel(service: PreviewTextRecognition())
        }

        /// A synthetic gradient image, never a real screenshot.
        static func image(width: Int = 480, height: Int = 320) -> CGImage? {
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            for row in stride(from: 0, to: height, by: 16) {
                let shade = CGFloat(row) / CGFloat(max(height, 1))
                context.setFillColor(red: 0.3, green: 0.5 + shade * 0.4, blue: 0.8, alpha: 1)
                context.fill(CGRect(x: 0, y: row, width: width, height: 8))
            }
            return context.makeImage()
        }
    }

    /// Seals nothing, so previews never create a keychain item.
    final class PreviewPreferenceIntegrity: PreferenceIntegrityService {
        func seal(_ data: Data) -> Data? { nil }
        func verify(_ data: Data, seal: Data) -> Bool { false }
    }

    final class PreviewPreferenceStorage: PreferenceStorage {
        private var values: [String: Data] = [:]
        func preferenceData(forKey key: String) -> Data? { values[key] }
        func setPreferenceData(_ data: Data?, forKey key: String) { values[key] = data }
    }

    final class PreviewShortcutRegistry: ShortcutRegistry {
        var failing: Set<String> = []
        var held: Set<String> = []
        func isAssigned(shortcutNamed name: String) -> Bool { failing.contains(name) || held.contains(name) }
        func isTakenBySystem(shortcutNamed name: String) -> Bool { held.contains(name) }
        func canRegister(shortcutNamed name: String) -> Bool { !failing.contains(name) }
        func setRegistered(_ registered: Bool, shortcutNamed name: String) {}
    }

    /// No display, window or permission: every capture and frame stream is refused.
    final class PreviewSystem: CaptureService, ScreenPermissionService, AccessibilityPermissionService,
        ScrollFrameSourceService
    {
        var isGranted: Bool { false }
        var isTrusted: Bool { false }
        func displays() -> [DisplayInfo] { [] }
        func windows() async throws(CaptureError) -> [WindowInfo] { [] }
        func capture(_ target: CaptureTarget, showsCursor: Bool, includesShadow: Bool) async throws(CaptureError)
            -> (CGImage, CaptureGeometry)
        {
            throw .permissionDenied
        }
        func request() async -> Bool { false }
        func requestWithPrompt() {}
        func start(_ target: CaptureTarget) async throws(CaptureError) { throw .permissionDenied }
        func nextFrame() async throws(CaptureError) -> CGImage { throw .canceled }
        func stop() {}
    }

    final class PreviewLoginItem: LoginItemService {
        var isEnabled = false
        func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
    }

    final class PreviewTextRecognition: TextRecognitionService {
        struct Unavailable: Error {}

        func supportedLanguages() async -> [Locale.Language] {
            [Locale.Language(identifier: "en-US"), Locale.Language(identifier: "pt-BR")]
        }

        func recognize(_ image: CGImage, languages: [Locale.Language]) async throws -> OCRResult {
            throw Unavailable()
        }
    }
#endif
