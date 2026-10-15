#if DEBUG || RECORTIA_FOREGROUND_HOST
    import AppKit
    import Foundation

    struct E2EForegroundState: Codable {
        let processIdentifier: pid_t
        let windowID: Int
        let frame: CGRect
        let key: Bool
        let active: Bool
        let foreground: Bool
        let visible: Bool
        let unoccluded: Bool
        let onActiveSpace: Bool
        let opaque: Bool
        let sequence: Int

        var ready: Bool {
            key && active && foreground && visible && unoccluded && onActiveSpace && opaque
        }

        static let argument = "-RecortiaE2EForegroundHost"

        static func requestName(_ session: String) -> Notification.Name {
            Notification.Name("dev.mvneves.Recortia.E2E.foreground.\(session)")
        }

        static func valid(_ frame: CGRect) -> Bool {
            [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite)
                && frame.width > 0 && frame.height > 0
        }
    }
#endif
