import ApplicationServices
import CoreGraphics

/// Screen Recording permission, requested just in time (SPEC.md §9, PERM-01).
public enum ScreenPermission {
    /// Whether capture is currently allowed. Never shows a prompt.
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks the system for access; the OS may show its prompt. Call only from an explicit
    /// user-initiated screen workflow.
    @discardableResult
    public static func request() -> Bool { CGRequestScreenCaptureAccess() }
}

/// Accessibility permission, used only by optional automatic scrolling (FR-10). Basic capture,
/// editing, import, export, and manual scrolling never consult it.
public enum AccessibilityPermission {
    /// Whether the process is trusted. Never shows a prompt.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks the system to show its Accessibility prompt. Call only after the user turned on
    /// automatic scrolling.
    public static func requestWithPrompt() {
        // The string value of kAXTrustedCheckOptionPrompt; the literal avoids reading the imported
        // global CFString from a nonisolated context.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
