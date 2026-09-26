import Foundation
import ServiceManagement

public enum LoginItemError: Error, Equatable, Sendable {
    /// Registered, but the user must approve it in System Settings > General > Login Items.
    case requiresApproval
    case failed(code: Int)
}

/// Launch at login through `SMAppService.mainApp` (FR-01). Off until the user turns it on; nothing
/// here registers automatically.
public enum LoginItem {
    @MainActor
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @MainActor
    public static func set(_ on: Bool) throws(LoginItemError) {
        let service = SMAppService.mainApp
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            throw .failed(code: (error as NSError).code)
        }
        if on, service.status == .requiresApproval { throw .requiresApproval }
    }
}

/// Which URLs may be handed to the system to open, and only after an explicit user action (FR-08,
/// THREAT_MODEL). QR payloads and recognized text are untrusted: only web links with a host pass.
public enum ExternalLinkPolicy {
    public static func canOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return false }
        return true
    }
}
