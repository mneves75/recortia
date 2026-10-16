import AppKit

/// How this process was started (FR-01, ADR-007).
enum LaunchKind: Equatable {
    /// Opened by the person (Finder, Spotlight, Dock, `open`).
    case user
    /// Started by "Open at login".
    case loginItem

    /// Reads the open-application event, current during `applicationDidFinishLaunching`. macOS
    /// marks a login item's launch with `keyAELaunchedAsLogInItem`; anything else, including no
    /// event, counts as the person's own launch, so a missing marker shows a window rather than
    /// hiding one.
    init(openEvent: NSAppleEventDescriptor?) {
        let marker = openEvent?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        self = marker == OSType(keyAELaunchedAsLogInItem) ? .loginItem : .user
    }
}

/// The window a launch shows: a menu-bar app is otherwise invisible after being opened.
enum LaunchWindow: Equatable {
    case onboarding, settings, none

    static func choose(onboardingPending: Bool, kind: LaunchKind) -> LaunchWindow {
        if onboardingPending { return .onboarding }
        return kind == .user ? .settings : .none
    }
}
