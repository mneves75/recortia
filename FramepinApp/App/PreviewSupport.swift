#if DEBUG
    import CoreGraphics
    import Features
    import Foundation
    import Imaging

    /// Debug-only stand-ins for Xcode previews. They never touch the screen, clipboard, TCC, or
    /// UserDefaults, and they are compiled out of Release builds.
    enum PreviewSupport {
        static func settings() -> SettingsStore {
            SettingsStore(storage: PreviewPreferenceStorage())
        }

        static func appModel() -> AppModel {
            AppModel(settings: settings(), services: nil, shortcutProbe: PreviewShortcutProbe())
        }

        static func shortcutStatus(failing: Set<String> = []) -> ShortcutStatusModel {
            let probe = PreviewShortcutProbe()
            probe.failing = failing
            let model = ShortcutStatusModel(probe: probe)
            for name in failing { model.shortcutChanged(named: name, isAssigned: true) }
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

    final class PreviewPreferenceStorage: PreferenceStorage {
        private var values: [String: Data] = [:]
        func preferenceData(forKey key: String) -> Data? { values[key] }
        func setPreferenceData(_ data: Data?, forKey key: String) { values[key] = data }
    }

    final class PreviewShortcutProbe: ShortcutRegistrationProbe {
        var failing: Set<String> = []
        func canRegister(shortcutNamed name: String) -> Bool { !failing.contains(name) }
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
